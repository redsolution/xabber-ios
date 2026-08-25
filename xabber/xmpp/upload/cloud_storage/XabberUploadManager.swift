//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

//import UIKit
import Foundation
import XMPPFramework
import Alamofire
import CocoaLumberjack
import RealmSwift
import Kingfisher
import RxCocoa

enum CloudStorageAvailabilityStage: String, Equatable {
    case discovery
    case authorization
    case quota
    case disconnected
}

enum CloudStorageAvailabilityState: Equatable {
    case discovering
    case authorizing(endpoint: URL)
    case ready(endpoint: URL)
    case unsupported
    case retryableFailure(stage: CloudStorageAvailabilityStage, endpoint: URL?)

    var endpoint: URL? {
        switch self {
        case .authorizing(let endpoint), .ready(let endpoint):
            return endpoint
        case .retryableFailure(_, let endpoint):
            return endpoint
        case .discovering, .unsupported:
            return nil
        }
    }
}

/// Serializes replayable availability transitions without holding a lock while
/// RxSwift synchronously notifies subscribers. A transition requested from a
/// subscriber (or another callback thread) is queued behind the current relay
/// emission, so concurrent callbacks cannot reorder state commits and relay
/// emissions.
final class CloudStorageAvailabilityPublisher {
    let relay: BehaviorRelay<CloudStorageAvailabilityState>

    private let lock = NSLock()
    private var pendingStates: [CloudStorageAvailabilityState] = []
    private var inFlightState: CloudStorageAvailabilityState?
    private var acceptedState: CloudStorageAvailabilityState
    private var isDraining = false
    private let willAccept: (CloudStorageAvailabilityState) -> Void

    init(
        initialState: CloudStorageAvailabilityState,
        willAccept: @escaping (CloudStorageAvailabilityState) -> Void = { _ in }
    ) {
        relay = BehaviorRelay(value: initialState)
        acceptedState = initialState
        self.willAccept = willAccept
    }

    func publish(_ state: CloudStorageAvailabilityState) {
        lock.lock()
        let latestScheduledState = pendingStates.last ?? inFlightState ?? acceptedState
        guard latestScheduledState != state else {
            lock.unlock()
            return
        }
        pendingStates.append(state)
        let shouldDrain = !isDraining
        isDraining = true
        lock.unlock()

        guard shouldDrain else { return }
        drain()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pendingStates.isEmpty else {
                inFlightState = nil
                isDraining = false
                lock.unlock()
                return
            }
            let state = pendingStates.removeFirst()
            inFlightState = state
            lock.unlock()

            willAccept(state)
            relay.accept(state)

            lock.lock()
            acceptedState = state
            inFlightState = nil
            lock.unlock()
        }
    }
}

enum CloudStorageQuotaRefreshReason: String {
    case appLaunch
    case foreground
    case galleryEndpointChanged
    case premiumEntitlementChanged
    case preUploadValidation
    case screenOpen
    case uploadCompleted
    case uploadQuotaExceeded
    case tokenReceived
    case manual
}

enum CloudStorageQuotaRefreshResult: String {
    case success
    case pending
    case unavailable
    case unauthorized
    case failure
}

extension Notification.Name {
    static let cloudStorageQuotaRefreshDidStart = Notification.Name("CloudStorageQuotaRefreshDidStart")
    static let cloudStorageQuotaRefreshDidFinish = Notification.Name("CloudStorageQuotaRefreshDidFinish")
    static let cloudStorageGalleryDidChange = Notification.Name("CloudStorageGalleryDidChange")
    static let cloudStorageGalleryTokenDidChange = Notification.Name("CloudStorageGalleryTokenDidChange")
    static let premiumEntitlementDidChange = Notification.Name("PremiumEntitlementDidChange")
}

enum AccountGalleryType: String, Equatable {
    case basic
    case premium

    var segmentTitle: String {
        switch self {
        case .basic: return "Hosted"
        case .premium: return "Premium"
        }
    }

    var displayTitle: String {
        switch self {
        case .basic: return "Basic Cloud Storage"
        case .premium: return "Premium Cloud Storage"
        }
    }
}

enum AccountGallerySelectionPolicy: Equatable {
    case unifiedHostedStorage
    case accountScopedSelection
}

struct AccountGalleryPremiumMetadata: Equatable {
    let storageMegabytes: Int?
    let storageDescription: String?
    let storageIncludes: [String]
    let messageRetention: String?
    let expires: Date?
    let displayName: String?

    var planDisplayText: String? {
        guard let storageMegabytes = storageMegabytes, storageMegabytes > 0 else {
            return displayName?.isNotEmpty == true ? displayName : nil
        }
        if storageMegabytes % 1024 == 0 {
            return "\(storageMegabytes / 1024) GB plan"
        }
        return "\(storageMegabytes) MB plan"
    }
}

struct AccountGalleryConfiguration: Equatable {
    private enum Keys {
        static let basicGalleryURL = "node"
        static let premiumGalleryURL = "premium_gallery_url"
        static let premiumAvailable = "premium_gallery_available"
        static let premiumStorageMegabytes = "premium_gallery_storage_mb"
        static let premiumStorageDescription = "premium_gallery_storage_description"
        static let premiumStorageIncludes = "premium_gallery_storage_includes"
        static let premiumMessageRetention = "premium_gallery_message_retention"
        static let premiumExpires = "premium_gallery_expires"
        static let premiumDisplayName = "premium_gallery_display_name"
        static let selectedGalleryType = "selected_gallery_type"
        static let manualSelection = "gallery_selection_manual"
        static let quotaGalleryType = "quota_gallery_type"
        static let quotaGalleryURL = "quota_gallery_url"
        static let legacyUserToken = "userToken"
        static let scopedUserTokenPrefix = "userToken"
    }

    let owner: String

    var selectionPolicy: AccountGallerySelectionPolicy {
        return Self.selectionPolicy(
            owner: owner,
            configuredDomain: CommonConfigManager.shared.config.domain
        )
    }

    var allowsManualGallerySelection: Bool {
        return selectionPolicy == .accountScopedSelection
    }

    var basicGalleryURL: URL? {
        return Self.normalizedBaseURL(from: storedString(for: Keys.basicGalleryURL))
    }

    var premiumGalleryURL: URL? {
        guard isPremiumGalleryAvailable else {
            return nil
        }
        return Self.normalizedBaseURL(from: storedString(for: Keys.premiumGalleryURL))
    }

    var selectedGalleryType: AccountGalleryType {
        let raw = storedString(for: Keys.selectedGalleryType) ?? AccountGalleryType.basic.rawValue
        let selected = AccountGalleryType(rawValue: raw) ?? .basic
        if selected == .premium && !isPremiumGalleryAvailable {
            return .basic
        }
        return selected
    }

    var currentGalleryType: AccountGalleryType {
        if selectedGalleryType == .premium, premiumGalleryURL != nil {
            return .premium
        }
        return .basic
    }

    var currentGalleryURL: URL? {
        switch currentGalleryType {
        case .basic:
            return basicGalleryURL
        case .premium:
            if selectionPolicy == .unifiedHostedStorage {
                return basicGalleryURL
            }
            return premiumGalleryURL
        }
    }

    var currentGalleryIdentity: String {
        return Self.galleryIdentity(owner: owner, type: currentGalleryType, url: currentGalleryURL)
    }

    var currentGalleryToken: String {
        guard let currentGalleryURL = currentGalleryURL else {
            return ""
        }
        return token(for: currentGalleryType, baseURL: currentGalleryURL)
    }

    var isPremiumGalleryAvailable: Bool {
        guard SettingManager.shared.getKeyBool(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable) == true else {
            return false
        }
        return Self.normalizedBaseURL(from: storedString(for: Keys.premiumGalleryURL)) != nil
    }

    var premiumGalleryMetadata: AccountGalleryPremiumMetadata? {
        guard isPremiumGalleryAvailable else {
            return nil
        }

        let storageMegabytes = storedString(for: Keys.premiumStorageMegabytes).flatMap(Int.init)
        let storageDescription = storedString(for: Keys.premiumStorageDescription)
        let storageIncludes = storedStringArray(for: Keys.premiumStorageIncludes)
        let messageRetention = storedString(for: Keys.premiumMessageRetention)
        let expires = storedString(for: Keys.premiumExpires).flatMap(Date.parseXMPPFormattedString)
        let displayName = storedString(for: Keys.premiumDisplayName)

        guard storageMegabytes != nil
            || storageDescription != nil
            || storageIncludes.isNotEmpty
            || messageRetention != nil
            || expires != nil
            || displayName != nil else {
            return nil
        }

        return AccountGalleryPremiumMetadata(
            storageMegabytes: storageMegabytes,
            storageDescription: storageDescription,
            storageIncludes: storageIncludes,
            messageRetention: messageRetention,
            expires: expires,
            displayName: displayName
        )
    }

    var currentGalleryPlanDisplayText: String? {
        guard currentGalleryType == .premium else {
            return nil
        }
        return premiumGalleryMetadata?.planDisplayText
    }

    var hasManualGallerySelection: Bool {
        return SettingManager.shared.getKeyBool(for: owner, scope: .xabberUploadManager, key: Keys.manualSelection) == true
    }

    @discardableResult
    func storeBasicGalleryURL(_ rawURL: String) -> Bool {
        let beforeType = currentGalleryType
        let beforeURL = currentGalleryURL
        guard let normalized = Self.normalizedBaseURLString(from: rawURL) else {
            return false
        }

        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.basicGalleryURL, value: normalized)
        postChangeIfNeeded(previousType: beforeType, previousURL: beforeURL)
        return true
    }

    func clearBasicGalleryURL() {
        let beforeType = currentGalleryType
        let beforeURL = currentGalleryURL
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.basicGalleryURL)
        postChangeIfNeeded(previousType: beforeType, previousURL: beforeURL)
    }

    @discardableResult
    func reconcilePremiumGalleryAvailability(
        isAvailable: Bool,
        storageURL: String?,
        metadata: AccountGalleryPremiumMetadata? = nil
    ) -> Bool {
        let beforeType = currentGalleryType
        let beforeURL = currentGalleryURL
        let beforeAvailable = self.isPremiumGalleryAvailable
        let beforeMetadata = self.premiumGalleryMetadata

        if isAvailable {
            let normalized = Self.normalizedBaseURLString(from: storageURL)
            if let normalized = normalized {
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumGalleryURL, value: normalized)
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable, value: true)
                savePremiumMetadata(metadata)
                if !allowsManualGallerySelection || !hasManualGallerySelection {
                    saveSelectedGalleryType(.premium, manual: false)
                }
            } else {
                SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumGalleryURL)
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable, value: false)
                clearPremiumMetadata()
                saveSelectedGalleryType(.basic, manual: false)
            }
        } else {
            SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumGalleryURL)
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable, value: false)
            clearPremiumMetadata()
            saveSelectedGalleryType(.basic, manual: false)
        }

        let didChange = beforeAvailable != self.isPremiumGalleryAvailable
            || beforeType != currentGalleryType
            || beforeURL != currentGalleryURL
            || beforeMetadata != self.premiumGalleryMetadata
        if didChange {
            postDidChange()
        }
        return didChange
    }

    @discardableResult
    func switchGallery(to type: AccountGalleryType, manual: Bool = true) -> Bool {
        guard !manual || allowsManualGallerySelection else {
            return false
        }
        switch type {
        case .basic:
            guard basicGalleryURL != nil else { return false }
        case .premium:
            guard isPremiumGalleryAvailable, premiumGalleryURL != nil else { return false }
        }

        let beforeType = currentGalleryType
        let beforeURL = currentGalleryURL
        saveSelectedGalleryType(type, manual: manual)
        postChangeIfNeeded(previousType: beforeType, previousURL: beforeURL)
        return currentGalleryType == type
    }

    func markQuotaStoredForCurrentGallery() {
        markQuotaStored(galleryType: currentGalleryType, galleryURL: currentGalleryURL)
    }

    func markQuotaStored(galleryType: AccountGalleryType, galleryURL: URL?) {
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.quotaGalleryType, value: galleryType.rawValue)
        if let galleryURL = galleryURL?.absoluteString {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.quotaGalleryURL, value: galleryURL)
        } else {
            SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.quotaGalleryURL)
        }
    }

    func cachedQuotaMatchesCurrentGallery() -> Bool {
        return cachedQuotaMatches(
            galleryType: currentGalleryType,
            galleryURL: currentGalleryURL
        )
    }

    func cachedQuotaMatches(
        galleryType: AccountGalleryType,
        galleryURL: URL?
    ) -> Bool {
        guard let storedType = storedString(for: Keys.quotaGalleryType) else {
            return galleryType == .basic
        }
        guard storedType == galleryType.rawValue else {
            return false
        }
        guard let storedURL = storedString(for: Keys.quotaGalleryURL) else {
            return true
        }
        return storedURL == galleryURL?.absoluteString
    }

    func token(for galleryType: AccountGalleryType, baseURL: URL) -> String {
        let key = Self.tokenStorageKey(galleryType: galleryType, baseURL: baseURL)
        return SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: key) ?? ""
    }

    func storeToken(_ token: String, galleryType: AccountGalleryType, baseURL: URL) {
        let key = Self.tokenStorageKey(galleryType: galleryType, baseURL: baseURL)
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: key, value: token)
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.legacyUserToken)
    }

    func clearToken(galleryType: AccountGalleryType, baseURL: URL) {
        let key = Self.tokenStorageKey(galleryType: galleryType, baseURL: baseURL)
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: key)
    }

    func clearKnownTokens() {
        let storedPremiumURL = Self.normalizedBaseURL(from: storedString(for: Keys.premiumGalleryURL))
        [
            basicGalleryURL.map { Self.tokenStorageKey(galleryType: .basic, baseURL: $0) },
            storedPremiumURL.map { Self.tokenStorageKey(galleryType: .premium, baseURL: $0) }
        ].compactMap { $0 }.forEach {
            SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: $0)
        }
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: Keys.legacyUserToken)
    }

    func galleryType(for baseURL: URL) -> AccountGalleryType? {
        let normalizedURL = Self.normalizedBaseURLString(from: baseURL.absoluteString)
        if normalizedURL == currentGalleryURL?.absoluteString {
            return currentGalleryType
        }
        if normalizedURL == basicGalleryURL?.absoluteString {
            return .basic
        }
        if normalizedURL == premiumGalleryURL?.absoluteString {
            return .premium
        }
        return nil
    }

    func clearPersistedState() {
        clearKnownTokens()

        [
            Keys.basicGalleryURL,
            Keys.premiumGalleryURL,
            Keys.premiumAvailable,
            Keys.premiumStorageMegabytes,
            Keys.premiumStorageDescription,
            Keys.premiumStorageIncludes,
            Keys.premiumMessageRetention,
            Keys.premiumExpires,
            Keys.premiumDisplayName,
            Keys.selectedGalleryType,
            Keys.manualSelection,
            Keys.quotaGalleryType,
            Keys.quotaGalleryURL,
            Keys.legacyUserToken
        ].forEach {
            SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: $0)
        }
    }

    static func apiURL(baseURL: URL, path: String) -> URL? {
        guard let base = normalizedBaseURLString(from: baseURL.absoluteString) else {
            return nil
        }
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: base + normalizedPath)
    }

    static func selectionPolicy(owner: String, configuredDomain: String) -> AccountGallerySelectionPolicy {
        guard let ownerDomain = normalizedDomain(fromOwner: owner),
              let configuredDomain = normalizedDomain(configuredDomain) else {
            return .accountScopedSelection
        }
        return ownerDomain == configuredDomain ? .unifiedHostedStorage : .accountScopedSelection
    }

    static func galleryIdentity(owner: String, type: AccountGalleryType, url: URL?) -> String {
        return [owner, type.rawValue, url?.absoluteString ?? ""].joined(separator: "|")
    }

    static func tokenStorageKey(galleryType: AccountGalleryType, baseURL: URL) -> String {
        let normalizedURL = normalizedBaseURLString(from: baseURL.absoluteString) ?? baseURL.absoluteString
        let digest = normalizedURL.sha256Data.hexEncodedString()
        return [Keys.scopedUserTokenPrefix, galleryType.rawValue, digest].joined(separator: "_")
    }

    static func galleryBaseURL(fromAuthURL rawURL: String?) -> URL? {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawURL.isNotEmpty,
              var components = URLComponents(string: rawURL),
              components.scheme?.isNotEmpty == true,
              components.host?.isNotEmpty == true else {
            return nil
        }

        let pathComponents = components.path.split(separator: "/")
        if let apiIndex = pathComponents.firstIndex(of: "api") {
            components.path = "/" + pathComponents[...apiIndex].joined(separator: "/")
            components.query = nil
            components.fragment = nil
            return normalizedBaseURL(from: components.string)
        }
        return normalizedBaseURL(from: rawURL)
    }

    static func normalizedBaseURL(from rawURL: String?) -> URL? {
        guard let normalized = normalizedBaseURLString(from: rawURL) else {
            return nil
        }
        return URL(string: normalized)
    }

    static func normalizedBaseURLString(from rawURL: String?) -> String? {
        guard var value = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }

        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.lowercased().hasSuffix("/v1") {
            value.removeLast(3)
            while value.hasSuffix("/") {
                value.removeLast()
            }
        }

        guard let url = URL(string: value),
              url.scheme?.isNotEmpty == true,
              url.host?.isNotEmpty == true else {
            return nil
        }
        return value + "/"
    }

    private static func normalizedDomain(fromOwner owner: String) -> String? {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        if let domain = XMPPJID(string: trimmedOwner)?.domain {
            return normalizedDomain(domain)
        }

        let bareOwner = trimmedOwner.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmedOwner
        guard let separator = bareOwner.lastIndex(of: "@") else {
            return normalizedDomain(bareOwner)
        }
        return normalizedDomain(String(bareOwner[bareOwner.index(after: separator)...]))
    }

    private static func normalizedDomain(_ rawDomain: String) -> String? {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") {
            domain.removeLast()
        }
        return domain.isNotEmpty ? domain : nil
    }

    private func storedString(for key: String) -> String? {
        return SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: key)
    }

    private func storedStringArray(for key: String) -> [String] {
        guard let raw = storedString(for: key),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [String] else {
            return []
        }
        return array
    }

    private func savePremiumMetadata(_ metadata: AccountGalleryPremiumMetadata?) {
        clearPremiumMetadata()
        guard let metadata = metadata else {
            return
        }
        if let storageMegabytes = metadata.storageMegabytes {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumStorageMegabytes, value: "\(storageMegabytes)")
        }
        if let storageDescription = metadata.storageDescription {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumStorageDescription, value: storageDescription)
        }
        if metadata.storageIncludes.isNotEmpty,
           let data = try? JSONSerialization.data(withJSONObject: metadata.storageIncludes),
           let rawIncludes = String(data: data, encoding: .utf8) {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumStorageIncludes, value: rawIncludes)
        }
        if let messageRetention = metadata.messageRetention {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumMessageRetention, value: messageRetention)
        }
        if let expires = metadata.expires {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumExpires, value: expires.XMPPFormattedDate)
        }
        if let displayName = metadata.displayName {
            SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumDisplayName, value: displayName)
        }
    }

    private func clearPremiumMetadata() {
        [
            Keys.premiumStorageMegabytes,
            Keys.premiumStorageDescription,
            Keys.premiumStorageIncludes,
            Keys.premiumMessageRetention,
            Keys.premiumExpires,
            Keys.premiumDisplayName
        ].forEach {
            SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: $0)
        }
    }

    private func saveSelectedGalleryType(_ type: AccountGalleryType, manual: Bool) {
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.selectedGalleryType, value: type.rawValue)
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.manualSelection, value: manual)
    }

    private func postChangeIfNeeded(previousType: AccountGalleryType, previousURL: URL?) {
        if previousType != currentGalleryType || previousURL != currentGalleryURL {
            postDidChange()
        }
    }

    private func postDidChange() {
        NotificationCenter.default.post(
            name: .cloudStorageGalleryDidChange,
            object: nil,
            userInfo: [
                "jid": owner,
                "galleryType": currentGalleryType.rawValue,
                "galleryURL": currentGalleryURL?.absoluteString ?? ""
            ]
        )
    }
}

struct CloudStorageGalleryRequestContext: Equatable {
    let owner: String
    let galleryType: AccountGalleryType
    let baseURL: URL
    let token: String

    var identity: String {
        return AccountGalleryConfiguration.galleryIdentity(owner: owner, type: galleryType, url: baseURL)
    }

    static func resolve(owner: String) -> CloudStorageGalleryRequestContext? {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let baseURL = configuration.currentGalleryURL else {
            return nil
        }
        let token = configuration.token(for: configuration.currentGalleryType, baseURL: baseURL)
        guard token.isNotEmpty else {
            return nil
        }
        return CloudStorageGalleryRequestContext(
            owner: owner,
            galleryType: configuration.currentGalleryType,
            baseURL: baseURL,
            token: token
        )
    }

    static func make(owner: String, galleryType: AccountGalleryType, baseURL: URL, token: String) -> CloudStorageGalleryRequestContext {
        return CloudStorageGalleryRequestContext(
            owner: owner,
            galleryType: galleryType,
            baseURL: baseURL,
            token: token
        )
    }

    func matchesCurrentSelection() -> Bool {
        return AccountGalleryConfiguration(owner: owner).currentGalleryIdentity == identity
    }
}

struct CloudStorageQuotaCategory: Equatable {
    let used: Int
    let count: Int
}

struct CloudStorageQuotaStatsPayload: Equatable {
    let quota: Int
    let total: CloudStorageQuotaCategory
    let images: CloudStorageQuotaCategory?
    let videos: CloudStorageQuotaCategory?
    let files: CloudStorageQuotaCategory?
    let audio: CloudStorageQuotaCategory?
    let voices: CloudStorageQuotaCategory?
    let avatars: CloudStorageQuotaCategory?

    static func parse(_ value: Any) -> CloudStorageQuotaStatsPayload? {
        guard let root = dictionary(from: value),
              let quota = int(from: root["quota"]),
              let totalRoot = dictionary(from: root["total"]),
              let totalUsed = int(from: totalRoot["used"]) else {
            return nil
        }

        return CloudStorageQuotaStatsPayload(
            quota: quota,
            total: CloudStorageQuotaCategory(used: totalUsed, count: int(from: totalRoot["count"]) ?? 0),
            images: category(from: root["images"]),
            videos: category(from: root["videos"]),
            files: category(from: root["files"]),
            audio: category(from: root["audio"]),
            voices: category(from: root["voices"]),
            avatars: category(from: root["avatars"])
        )
    }

    private static func category(from value: Any?) -> CloudStorageQuotaCategory? {
        guard let root = dictionary(from: value) else { return nil }
        guard int(from: root["used"]) != nil || int(from: root["count"]) != nil else { return nil }
        return CloudStorageQuotaCategory(
            used: int(from: root["used"]) ?? 0,
            count: int(from: root["count"]) ?? 0
        )
    }

    private static func dictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }

    private static func int(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

struct CloudStorageUploadSlotRequest {
    let size: Int
    let name: String
    let hash: String
}

struct CloudStorageQuotaAPINetworkDiagnostics {
    let request: URLRequest?
    let response: HTTPURLResponse?
    let metrics: URLSessionTaskMetrics?
    let error: Error?
    let sessionConfiguration: URLSessionConfiguration?

    func traceDetails() -> [(String, Any?)] {
        var details: [(String, Any?)] = []
        if let request {
            details.append(("requestMethod", request.httpMethod))
            details.append(("requestURL", Self.sanitizedURLString(request.url)))
            details.append(("requestHost", request.url?.host))
            details.append(("requestPath", Self.pathString(request.url)))
            details.append(("requestQueryKeys", Self.queryKeysString(request.url)))
            details.append(("requestTimeoutSeconds", request.timeoutInterval))
        }
        if let response {
            details.append(("responseStatusCode", response.statusCode))
            details.append(("responseURL", Self.sanitizedURLString(response.url)))
        }
        if let metrics {
            details.append(("metricsDurationMs", Self.milliseconds(from: metrics.taskInterval.duration)))
            details.append(("metricsRedirectCount", metrics.redirectCount))
            details.append(("metricsTransactionCount", metrics.transactionMetrics.count))
            if let transaction = metrics.transactionMetrics.last {
                details.append(("metricsFetchType", String(describing: transaction.resourceFetchType)))
                details.append(("metricsNetworkProtocol", transaction.networkProtocolName))
                details.append(("metricsReusedConnection", transaction.isReusedConnection))
                details.append(("metricsProxyConnection", transaction.isProxyConnection))
                details.append(("metricsDNSMs", Self.milliseconds(from: transaction.domainLookupStartDate, to: transaction.domainLookupEndDate)))
                details.append(("metricsConnectMs", Self.milliseconds(from: transaction.connectStartDate, to: transaction.connectEndDate)))
                details.append(("metricsTLSMs", Self.milliseconds(from: transaction.secureConnectionStartDate, to: transaction.secureConnectionEndDate)))
                details.append(("metricsRequestMs", Self.milliseconds(from: transaction.requestStartDate, to: transaction.requestEndDate)))
                details.append(("metricsResponseMs", Self.milliseconds(from: transaction.responseStartDate, to: transaction.responseEndDate)))
            }
        }
        if let sessionConfiguration {
            details.append(("sessionRequestTimeoutSeconds", sessionConfiguration.timeoutIntervalForRequest))
            details.append(("sessionResourceTimeoutSeconds", sessionConfiguration.timeoutIntervalForResource))
            details.append(("waitsForConnectivity", sessionConfiguration.waitsForConnectivity))
            details.append(("allowsCellularAccess", sessionConfiguration.allowsCellularAccess))
            details.append(("allowsExpensiveNetworkAccess", sessionConfiguration.allowsExpensiveNetworkAccess))
            details.append(("allowsConstrainedNetworkAccess", sessionConfiguration.allowsConstrainedNetworkAccess))
        }
        if let error {
            let errorChain = Self.errorChain(from: error)
            let nsError = errorChain.first
            details.append(("failingURL", Self.sanitizedURLString(Self.failingURL(from: errorChain))))
            details.append(("networkErrorChain", Self.errorChainString(errorChain)))
            details.append(("urlSessionTask", Self.userInfoStringValue(for: "_NSURLErrorFailingURLSessionTaskErrorKey", in: errorChain)))
            details.append(("relatedURLSessionTasks", Self.userInfoStringValue(for: "_NSURLErrorRelatedURLSessionTaskErrorKey", in: errorChain)))
            details.append(("errorDescription", nsError.map { Self.sanitizedDiagnosticText($0.localizedDescription) }))
            details.append(("errorFailureReason", errorChain.compactMap(\.localizedFailureReason).first.map(Self.sanitizedDiagnosticText)))
            details.append(("errorRecoverySuggestion", errorChain.compactMap(\.localizedRecoverySuggestion).first.map(Self.sanitizedDiagnosticText)))
        }
        return details
    }

    private static func sanitizedURLString(_ url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var base = ""
        if let scheme = components.scheme {
            base += "\(scheme)://"
        }
        if let host = components.host {
            base += host
        }
        if let port = components.port {
            base += ":\(port)"
        }
        base += components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath

        guard let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return base
        }
        let redactedQuery = queryItems
            .map { "\($0.name)=<redacted>" }
            .joined(separator: "&")
        return "\(base)?\(redactedQuery)"
    }

    private static func pathString(_ url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }

    private static func queryKeysString(_ url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }
        return queryItems
            .map(\.name)
            .sorted()
            .joined(separator: ",")
    }

    private static func failingURL(from errorChain: [NSError]) -> URL? {
        for error in errorChain {
            if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                return url
            }
            if let url = error.userInfo["NSErrorFailingURLKey"] as? URL {
                return url
            }
            if let urlString = error.userInfo["NSErrorFailingURLStringKey"] as? String,
               let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private static func errorChain(from error: Error?) -> [NSError] {
        var result: [NSError] = []

        func append(_ error: Error?, depth: Int) {
            guard let error, depth < 8 else { return }
            let nsError = error as NSError
            result.append(nsError)

            if let afError = error as? AFError, let underlyingError = afError.underlyingError {
                append(underlyingError, depth: depth + 1)
                return
            }

            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                append(underlyingError, depth: depth + 1)
            }
        }

        append(error, depth: 0)
        return result
    }

    private static func errorChainString(_ errorChain: [NSError]) -> String? {
        guard errorChain.isNotEmpty else { return nil }
        return errorChain.map { "\($0.domain):\($0.code)" }.joined(separator: ">")
    }

    private static func userInfoStringValue(for key: String, in errorChain: [NSError]) -> String? {
        for error in errorChain {
            guard let value = error.userInfo[key] else { continue }
            if let values = value as? [Any] {
                return values.map { sanitizedDiagnosticText(String(describing: $0)) }.joined(separator: ",")
            }
            return sanitizedDiagnosticText(String(describing: value))
        }
        return nil
    }

    private static func sanitizedDiagnosticText(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"([?&][^=\s&#]+)=([^&\s#]+)"#,
                with: "$1=<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"Bearer\s+[A-Za-z0-9._~+/=-]+"#,
                with: "Bearer <redacted>",
                options: .regularExpression
            )
    }

    private static func milliseconds(from interval: TimeInterval?) -> Int? {
        guard let interval else { return nil }
        return Int((interval * 1000).rounded())
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return milliseconds(from: end.timeIntervalSince(start))
    }
}

enum CloudStorageQuotaAPIResponse {
    case response(statusCode: Int?, value: Any?, diagnostics: CloudStorageQuotaAPINetworkDiagnostics? = nil)
    case failure(statusCode: Int?, error: Error?, diagnostics: CloudStorageQuotaAPINetworkDiagnostics? = nil)
}

protocol CloudStorageQuotaAPIClient {
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, traceID: String, timeoutInterval: TimeInterval, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, fileMimeType: String, galleryMediaType: String, metadata: [String: String]?, context: String, traceID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func deleteMedia(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func deleteAvatar(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func deleteGallery(baseURL: URL, token: String, jid: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func getFiles(baseURL: URL, token: String, type: MimeIconTypes, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func getAvatars(baseURL: URL, token: String, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func deleteMediaForAll(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
}

protocol CloudStorageTokenAPIClient {
    func requestCode(baseURL: URL, fullJID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func exchangeCode(baseURL: URL, owner: String, code: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
}

final class AlamofireCloudStorageTokenAPIClient: CloudStorageTokenAPIClient {
    func requestCode(baseURL: URL, fullJID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = AccountGalleryConfiguration.apiURL(baseURL: baseURL, path: "v1/account/xmpp_code_request/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(
            url,
            method: .post,
            parameters: ["jid": fullJID, "type": "iq"],
            encoding: JSONEncoding.default,
            headers: HTTPHeaders([:])
        ).responseJSON { AlamofireCloudStorageQuotaAPIClient.complete($0, completion: completion) }
    }

    func exchangeCode(baseURL: URL, owner: String, code: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = AccountGalleryConfiguration.apiURL(baseURL: baseURL, path: "v1/account/xmpp_auth/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(
            url,
            method: .post,
            parameters: ["code": code, "jid": owner],
            encoding: JSONEncoding.default,
            headers: HTTPHeaders([:])
        ).responseJSON { AlamofireCloudStorageQuotaAPIClient.complete($0, completion: completion) }
    }
}

final class AlamofireCloudStorageQuotaAPIClient: CloudStorageQuotaAPIClient {
    private static let traceHeaderName = "X-Xabber-Trace-ID"

    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/stats/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(
            url,
            method: .get,
            parameters: nil,
            encoding: JSONEncoding.default,
            headers: Self.authHeaders(token)
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, traceID: String, timeoutInterval: TimeInterval, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/slot/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        do {
            var urlRequest = try URLRequest(url: url, method: .get, headers: Self.authHeaders(token, traceID: traceID))
            urlRequest.timeoutInterval = timeoutInterval
            let encodedRequest = try URLEncoding.default.encode(urlRequest, with: [
                "size": request.size,
                "name": request.name,
                "hash": request.hash
            ])
            AF.request(encodedRequest).responseJSON { Self.complete($0, completion: completion) }
        } catch {
            completion(.failure(statusCode: nil, error: error))
        }
    }

    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, fileMimeType: String, galleryMediaType: String, metadata: [String: String]?, context: String, traceID: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/upload/"),
              let mediaTypeData = galleryMediaType.data(using: .utf8),
              let contextData = context.data(using: .utf8) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        let metadataData = metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        AF.upload(
            multipartFormData: { formData in
                formData.append(data, withName: "file", fileName: filename, mimeType: fileMimeType)
                formData.append(mediaTypeData, withName: "media_type")
                formData.append(contextData, withName: "context")
                if let metadataData = metadataData {
                    formData.append(metadataData, withName: "metadata")
                }
            },
            to: url,
            method: .post,
            headers: Self.authHeaders(token, traceID: traceID)
        ).validate().responseJSON { Self.complete($0, completion: completion) }
    }

    func deleteMedia(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        requestDelete(baseURL: baseURL, token: token, path: "v1/files/", parameters: ["id": fileID], completion: completion)
    }

    func deleteAvatar(baseURL: URL, token: String, fileID: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        requestDelete(baseURL: baseURL, token: token, path: "v1/avatar/", parameters: ["id": fileID], completion: completion)
    }

    func deleteGallery(baseURL: URL, token: String, jid: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        requestDelete(baseURL: baseURL, token: token, path: "v1/account/", parameters: ["jid": jid], completion: completion)
    }

    func getFiles(baseURL: URL, token: String, type: MimeIconTypes, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let typeValue = Self.fileTypeQueryValue(for: type) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: typeValue),
            URLQueryItem(name: "page", value: String(page))
        ]

        AF.request(
            components,
            method: .get,
            parameters: nil,
            encoding: JSONEncoding.default,
            headers: Self.authHeaders(token)
        ).validate(statusCode: 200..<300)
            .responseJSON { Self.complete($0, completion: completion) }
    }

    func getAvatars(baseURL: URL, token: String, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/avatar/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        AF.request(
            components,
            method: .get,
            parameters: nil,
            encoding: JSONEncoding.default,
            headers: Self.authHeaders(token)
        ).validate(statusCode: 200..<300)
            .responseJSON { Self.complete($0, completion: completion) }
    }

    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let request = Self.cleanupPreviewRequest(
            baseURL: baseURL,
            token: token,
            percent: percent,
            page: page
        ) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(request)
            .validate(statusCode: 200..<300)
            .responseJSON(emptyResponseCodes: Set(200..<300)) {
                Self.complete($0, completion: completion)
            }
    }

    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let request = Self.cleanupDeleteRequest(
            baseURL: baseURL,
            token: token,
            percent: percent
        ) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(request)
            .validate(statusCode: 200..<300)
            .responseJSON(emptyResponseCodes: Set(200..<300)) {
                Self.complete($0, completion: completion)
            }
    }

    static func cleanupPreviewRequest(
        baseURL: URL,
        token: String,
        percent: Int,
        page: Int
    ) -> URLRequest? {
        guard XabberUploadManager.supportedCleanupPercents.contains(percent),
              page > 0,
              let url = Self.apiURL(baseURL: baseURL, path: "v1/files/percent/\(percent)/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "exclude_avatars", value: "true")
        ]
        guard let requestURL = components.url else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = HTTPMethod.get.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func cleanupDeleteRequest(
        baseURL: URL,
        token: String,
        percent: Int
    ) -> URLRequest? {
        guard XabberUploadManager.supportedCleanupPercents.contains(percent),
              let url = Self.apiURL(baseURL: baseURL, path: "v1/files/percent/\(percent)/"),
              let body = try? JSONSerialization.data(withJSONObject: ["exclude_avatars": true]) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.delete.rawValue
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func deleteMediaForAll(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        components.queryItems = [
            URLQueryItem(name: "context", value: XabberUploadManager.FilesContext.avatar.rawValue),
            URLQueryItem(name: "context", value: XabberUploadManager.FilesContext.voice.rawValue),
            URLQueryItem(name: "context", value: XabberUploadManager.FilesContext.file.rawValue)
        ]
        AF.request(
            components,
            method: .delete,
            parameters: [:],
            encoding: JSONEncoding.default,
            headers: Self.authHeaders(token)
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    private static func apiURL(baseURL: URL, path: String) -> URL? {
        return AccountGalleryConfiguration.apiURL(baseURL: baseURL, path: path)
    }

    static func fileTypeQueryValue(for type: MimeIconTypes) -> String? {
        switch type {
        case .image:
            return "image"
        case .video:
            return "video"
        case .file:
            return "file"
        case .audio:
            return "voice"
        case .avatar:
            return nil
        default:
            return type.rawValue
        }
    }

    private static func authHeaders(_ token: String, traceID: String? = nil) -> HTTPHeaders {
        var headers = ["Authorization": "Bearer \(token)"]
        if let traceID = traceID, traceID.isNotEmpty {
            headers[traceHeaderName] = traceID
        }
        return HTTPHeaders(headers)
    }

    private func requestDelete(baseURL: URL, token: String, path: String, parameters: [String: Any], completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: path) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(
            url,
            method: .delete,
            parameters: parameters,
            encoding: JSONEncoding.default,
            headers: Self.authHeaders(token)
        ).validate(statusCode: 200..<300)
            .responseJSON(emptyResponseCodes: Set(200..<300)) {
                Self.complete($0, completion: completion)
            }
    }

    static func complete(_ response: AFDataResponse<Any>, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        let diagnostics = CloudStorageQuotaAPINetworkDiagnostics(
            request: response.request,
            response: response.response,
            metrics: response.metrics,
            error: response.error,
            sessionConfiguration: AF.sessionConfiguration
        )
        switch response.result {
        case .success(let value):
            completion(.response(statusCode: response.response?.statusCode, value: value, diagnostics: diagnostics))
        case .failure(let error):
            completion(.failure(statusCode: response.response?.statusCode, error: error, diagnostics: diagnostics))
        }
    }
}

final class CloudStorageQuotaRefreshCoordinator {
    static let shared = CloudStorageQuotaRefreshCoordinator()

    var ownersProvider: () -> [String] = {
        AccountManager.shared.users.map { $0.jid }
    }

    var refreshOwnerHandler: (String, CloudStorageQuotaRefreshReason, Bool, ((CloudStorageQuotaRefreshResult) -> Void)?) -> Void = {
        owner, reason, force, completion in
        guard let account = AccountManager.shared.find(for: owner) else {
            completion?(.unavailable)
            return
        }
        account.action { user, _ in
            user.cloudStorage.refreshQuota(reason: reason, force: force, completion: completion)
        }
    }

    var availabilityResumeOwnerHandler: (String) -> Void = { owner in
        guard let account = AccountManager.shared.find(for: owner) else {
            return
        }
        account.action { user, stream in
            guard stream.isAuthenticated else {
                return
            }
            user.cloudStorage.resumeAvailabilityWorkIfNeeded(
                stream: stream,
                disco: user.disco
            )
        }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(premiumEntitlementDidChange(_:)),
            name: .premiumEntitlementDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
    }

    func refreshAll(reason: CloudStorageQuotaRefreshReason, force: Bool = false) {
        ownersProvider().forEach {
            refresh(owner: $0, reason: reason, force: force)
        }
    }

    func refresh(owner: String, reason: CloudStorageQuotaRefreshReason, force: Bool = false, completion: ((CloudStorageQuotaRefreshResult) -> Void)? = nil) {
        guard owner.isNotEmpty else {
            completion?(.unavailable)
            return
        }
        if reason == .foreground {
            availabilityResumeOwnerHandler(owner)
        }
        refreshOwnerHandler(owner, reason, force, completion)
    }

    @objc private func premiumEntitlementDidChange(_ notification: Notification) {
        guard let owner = notification.userInfo?["jid"] as? String else { return }
        refresh(owner: owner, reason: .premiumEntitlementChanged, force: true)
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard let owner = notification.userInfo?["jid"] as? String else { return }
        AccountManager.shared.find(for: owner)?.action { user, _ in
            user.cloudStorage.reconcileSelectedGalleryAvailability()
        }
        refresh(owner: owner, reason: .galleryEndpointChanged, force: true)
    }

    func resetTestingHooks() {
        ownersProvider = { AccountManager.shared.users.map { $0.jid } }
        availabilityResumeOwnerHandler = { owner in
            guard let account = AccountManager.shared.find(for: owner) else {
                return
            }
            account.action { user, stream in
                guard stream.isAuthenticated else {
                    return
                }
                user.cloudStorage.resumeAvailabilityWorkIfNeeded(
                    stream: stream,
                    disco: user.disco
                )
            }
        }
        refreshOwnerHandler = { owner, reason, force, completion in
            guard let account = AccountManager.shared.find(for: owner) else {
                completion?(.unavailable)
                return
            }
            account.action { user, _ in
                user.cloudStorage.refreshQuota(reason: reason, force: force, completion: completion)
            }
        }
    }
}


/**
*       XabberUploadManager sends inquiry to the server, which gets non-permanent code.
*       It is used for receiving user's token for messages and files exchange
**/
class XabberUploadManager: AbstractXMPPManager {
    enum UploadError: Error {
        case notAvailable
    }

    enum QuotaFileTypes: String, CaseIterable {
        case images = "image"
        case videos = "video"
        case files = "application"
        case audio = "audio"
    }

    private static let httpAuthNamespace: String = "http://jabber.org/protocol/http-auth"
    static var quotaAPIClient: CloudStorageQuotaAPIClient = AlamofireCloudStorageQuotaAPIClient()
    static var tokenAPIClient: CloudStorageTokenAPIClient = AlamofireCloudStorageTokenAPIClient()
    static var tokenExpiredTestingHandler: ((CloudStorageGalleryRequestContext) -> Void)?
    static var authorizationSuccessWillCommitTestingHandler: (() -> Void)?
    static var networkPathMonitorFactory: () -> AccountNetworkPathMonitoring? = { AccountNWPathMonitor() }
    static var authorizationTimeoutInterval: TimeInterval = 10

    internal var node: String? = nil

    internal var namespace: String = ""
    internal var maxFileSize: Int? = nil
    private let quotaRefreshLock = NSLock()
    private var isQuotaRefreshInFlight = false
    private var quotaRefreshInFlightContext: CloudStorageGalleryRequestContext?
    private var quotaRefreshGeneration = 0
    private var quotaRefreshCallbacks: [(CloudStorageQuotaRefreshResult) -> Void] = []
    private let gallerySlotQueueLock = NSRecursiveLock()
    private var gallerySlotQueue: [GallerySlotQueueItem] = []
    private var isGallerySlotRequestRunning = false
    private let galleryNetworkPathLock = NSLock()
    private let galleryNetworkPathQueue = DispatchQueue(label: "com.xabber.gallery.network-path")
    private var galleryNetworkPathMonitor: AccountNetworkPathMonitoring?
    private var galleryNetworkPathSnapshot: AccountNetworkPathSnapshot?
    private var galleryNetworkPathGeneration = 0
    private let availabilityPublisher: CloudStorageAvailabilityPublisher
    let availabilityRelay: BehaviorRelay<CloudStorageAvailabilityState>
    private let authorizationLock = NSRecursiveLock()
    private var authorizationGeneration = 0
    private var authorizationInFlightIdentity: String?
    private var authorizationInFlightGeneration: Int?
    private var tokenExchangeInFlightIdentity: String?
    private var authorizationTimeoutWorkItem: DispatchWorkItem?

    var token: String {
        get {
            return AccountGalleryConfiguration(owner: owner).currentGalleryToken
        }
        set {
            let configuration = AccountGalleryConfiguration(owner: owner)
            guard let baseURL = configuration.currentGalleryURL else {
                return
            }
            configuration.storeToken(newValue, galleryType: configuration.currentGalleryType, baseURL: baseURL)
        }
    }


    override init(withOwner owner: String) {
        let initialAvailabilityState = Self.initialAvailabilityState(owner: owner)
        let availabilityPublisher = CloudStorageAvailabilityPublisher(
            initialState: initialAvailabilityState,
            willAccept: { state in
                DDLogDebug(
                    "CLOUD_AVAILABILITY state=\(XabberUploadManager.diagnosticName(for: state)) endpointKnown=\(state.endpoint != nil)"
                )
            }
        )
        self.availabilityPublisher = availabilityPublisher
        self.availabilityRelay = availabilityPublisher.relay
        super.init(withOwner: owner)
        startGalleryNetworkPathMonitoring()
    }

    deinit {
        authorizationTimeoutWorkItem?.cancel()
        galleryNetworkPathMonitor?.cancel()
    }

    open func isAvailable() -> Bool {
        guard let context = currentGalleryRequestContext() else {
            return false
        }
        self.node = context.baseURL.absoluteString
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size") ?? "")
        return true
    }

    func beginAvailabilityDiscovery() {
        switch availabilityRelay.value {
        case .ready, .authorizing:
            return
        case .retryableFailure(_, let endpoint) where endpoint != nil:
            return
        case .discovering, .unsupported, .retryableFailure:
            publishAvailability(.discovering)
        }
    }

    func resolveAuthoritativeDiscovery(endpoint: URL?) {
        let configuration = AccountGalleryConfiguration(owner: owner)
        if let endpoint = endpoint,
           let normalizedEndpoint = AccountGalleryConfiguration.normalizedBaseURL(from: endpoint.absoluteString) {
            _ = configuration.storeBasicGalleryURL(normalizedEndpoint.absoluteString)
            reconcileSelectedGalleryAvailability()
            return
        }

        configuration.clearBasicGalleryURL()
        if configuration.currentGalleryURL != nil {
            synchronizeAvailabilityWithCurrentConfiguration()
        } else {
            cancelAuthorization()
            publishAvailability(.unsupported)
        }
    }

    func markAvailabilityRetryableFailure(stage: CloudStorageAvailabilityStage) {
        if case .unsupported = availabilityRelay.value, stage == .disconnected {
            return
        }
        if stage == .disconnected,
           case .retryableFailure(let existingStage, let endpoint) = availabilityRelay.value {
            publishAvailability(.retryableFailure(stage: existingStage, endpoint: endpoint))
            return
        }
        if stage == .authorization || stage == .disconnected {
            cancelAuthorization()
        }
        let endpoint = availabilityRelay.value.endpoint
            ?? AccountGalleryConfiguration(owner: owner).currentGalleryURL
        publishAvailability(.retryableFailure(stage: stage, endpoint: endpoint))
    }

    func resumeAvailabilityWorkIfNeeded(
        stream xmppStream: XMPPStream,
        disco: ServerDiscoManager
    ) {
        let configuration = AccountGalleryConfiguration(owner: owner)

        func resumeAuthorizationOrDiscovery() {
            guard let endpoint = configuration.currentGalleryURL else {
                disco.requestServerFeatures(xmppStream)
                return
            }
            let galleryType = configuration.currentGalleryType
            if configuration.token(for: galleryType, baseURL: endpoint).isNotEmpty {
                publishAvailability(.ready(endpoint: endpoint))
            } else {
                requestAuthIfNeeded(galleryType: galleryType, baseURL: endpoint)
            }
        }

        switch availabilityRelay.value {
        case .unsupported, .ready:
            return
        case .discovering:
            disco.requestServerFeatures(xmppStream)
        case .authorizing:
            resumeAuthorizationOrDiscovery()
        case .retryableFailure(let stage, _):
            switch stage {
            case .discovery:
                disco.requestServerFeatures(xmppStream)
            case .authorization, .disconnected:
                resumeAuthorizationOrDiscovery()
            case .quota:
                guard currentGalleryRequestContext() != nil else {
                    resumeAuthorizationOrDiscovery()
                    return
                }
                refreshQuota(reason: .foreground, force: true)
            }
        }
    }

    func noteTokenResolved(galleryType: AccountGalleryType, endpoint: URL) {
        let target = GalleryTokenRequestTarget(owner: owner, galleryType: galleryType, baseURL: endpoint)
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard configuration.token(for: galleryType, baseURL: endpoint).isNotEmpty else {
            return
        }
        finishPendingAuthorizationIfTokenResolved(identity: target.identity)
        guard configuration.currentGalleryIdentity == target.identity else { return }
        publishAvailability(.ready(endpoint: endpoint))
    }

    private static func initialAvailabilityState(owner: String) -> CloudStorageAvailabilityState {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let endpoint = configuration.currentGalleryURL else {
            return .discovering
        }
        if configuration.token(for: configuration.currentGalleryType, baseURL: endpoint).isNotEmpty {
            return .ready(endpoint: endpoint)
        }
        return .authorizing(endpoint: endpoint)
    }

    private func synchronizeAvailabilityWithCurrentConfiguration() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let endpoint = configuration.currentGalleryURL else {
            return
        }
        self.node = endpoint.absoluteString
        if configuration.token(for: configuration.currentGalleryType, baseURL: endpoint).isNotEmpty {
            publishAvailability(.ready(endpoint: endpoint))
        } else {
            publishAvailability(.authorizing(endpoint: endpoint))
        }
    }

    func reconcileSelectedGalleryAvailability() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let endpoint = configuration.currentGalleryURL else {
            return
        }
        let galleryType = configuration.currentGalleryType
        synchronizeAvailabilityWithCurrentConfiguration()
        requestAuthIfNeeded(galleryType: galleryType, baseURL: endpoint)
    }

    private func publishAvailability(_ state: CloudStorageAvailabilityState) {
        availabilityPublisher.publish(state)
    }

    private static func diagnosticName(for state: CloudStorageAvailabilityState) -> String {
        switch state {
        case .discovering: return "discovering"
        case .authorizing: return "authorizing"
        case .ready: return "ready"
        case .unsupported: return "unsupported"
        case .retryableFailure(let stage, _): return "retryable-\(stage.rawValue)"
        }
    }

    func currentGalleryRequestContext() -> CloudStorageGalleryRequestContext? {
        return CloudStorageGalleryRequestContext.resolve(owner: owner)
    }

    private func isCurrent(_ context: CloudStorageGalleryRequestContext) -> Bool {
        return context.matchesCurrentSelection()
    }

    enum XabberUploaderError: Error {
        case unauthorized
        case unexpected
    }

    struct UploadErrorResponse: Codable {
        let status: Int
        let error: String
    }

    private final func checkResponse(_ code: Int?, success: (() -> Void)? = nil, fail: ((Error?) -> Void)? = nil) {
        guard let code = code else {
            fail?(nil)
            return
        }
        if code >= 200 && code < 300 {
            success?()
        } else if code == 401 {
            fail?(XabberUploaderError.unauthorized)
        } else if code > 401 {
            fail?(XabberUploaderError.unexpected)
        }
    }

    private func uploadContext(for mimeType: String?, metadata: [String: String]?) -> String {
        if metadata?["meters"] != nil || metadata?["duration"] != nil || mimeType == "voice" {
            return "voice"
        }
        return "file"
    }

    private func galleryMediaType(_ mimeType: String, context: String) -> String {
        guard context == "voice",
              mimeType.hasPrefix("audio/"),
              !mimeType.contains("+voice") else {
            return mimeType
        }
        return mimeType + "+voice"
    }

    private enum GalleryUploadEndpoint: String {
        case slot
        case upload
    }

    struct MediaUploadDiagnosticContext {
        let messagePrimary: String?
        let referencePrimary: String?
    }

    private struct GalleryRequestAttemptContext {
        let traceID: String
        let attempt: Int
        let maxAttempts: Int
        let networkPathGeneration: Int
        let isNetworkPathBonusAttempt: Bool
    }

    private struct GallerySlotQueueItem {
        let id: String
        let filename: String
        let traceContext: MediaUploadDiagnosticContext?
        let traceDetails: [(String, Any?)]
        let start: (@escaping () -> Void) -> Void
    }

    private var galleryUploadMaxRetryAttempts: Int {
        3
    }

    private var gallerySlotRequestTimeout: TimeInterval {
        15
    }

    private func performGalleryRequestWithRetry(
        endpoint: GalleryUploadEndpoint,
        filename: String,
        attempt: Int = 1,
        initialNetworkPathGeneration: Int? = nil,
        usedNetworkPathBonusAttempt: Bool = false,
        traceContext: MediaUploadDiagnosticContext? = nil,
        traceDetails: [(String, Any?)] = [],
        operation: @escaping (GalleryRequestAttemptContext, @escaping (CloudStorageQuotaAPIResponse) -> Void) -> Void,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        let networkPathGeneration = currentGalleryNetworkPathGeneration()
        let initialNetworkPathGeneration = initialNetworkPathGeneration ?? networkPathGeneration
        let attemptContext = GalleryRequestAttemptContext(
            traceID: UUID().uuidString,
            attempt: attempt,
            maxAttempts: galleryUploadMaxRetryAttempts,
            networkPathGeneration: networkPathGeneration,
            isNetworkPathBonusAttempt: usedNetworkPathBonusAttempt && attempt > galleryUploadMaxRetryAttempts
        )
        logMediaUploadTrace(
            "gallery_\(endpoint.rawValue)_request_started",
            details: mediaUploadTraceDetails(
                context: traceContext,
                extra: traceDetails + [
                    ("endpoint", endpoint.rawValue),
                    ("filename", filename),
                    ("attempt", attemptContext.attempt),
                    ("maxAttempts", attemptContext.maxAttempts),
                    ("traceID", attemptContext.traceID),
                    ("networkPathGeneration", attemptContext.networkPathGeneration),
                    ("networkPathBonusAttempt", attemptContext.isNetworkPathBonusAttempt),
                    ("timeout", endpoint == .slot ? gallerySlotRequestTimeout : nil)
                ] + currentGalleryNetworkPathTraceDetails()
            )
        )
        operation(attemptContext) { [weak self] response in
            guard let self else {
                completion(response)
                return
            }

            let isRetryable = self.isRetryableGalleryResponse(response)
            let isSlotTimeoutFallback = endpoint == .slot && self.isGalleryTimeoutResponse(response)
            if isRetryable, !isSlotTimeoutFallback, attempt < self.galleryUploadMaxRetryAttempts {
                self.logMediaUploadTrace(
                    "gallery_\(endpoint.rawValue)_request_retry",
                    details: self.mediaUploadTraceDetails(
                        context: traceContext,
                        extra: traceDetails + [
                            ("endpoint", endpoint.rawValue),
                            ("filename", filename),
                            ("attempt", attemptContext.attempt),
                            ("nextAttempt", attempt + 1),
                            ("maxAttempts", self.galleryUploadMaxRetryAttempts),
                            ("traceID", attemptContext.traceID),
                            ("networkPathGeneration", attemptContext.networkPathGeneration),
                            ("retryReason", "retryableResponse")
                        ] + self.mediaUploadResponseTraceDetails(response)
                    )
                )
                self.performGalleryRequestWithRetry(
                    endpoint: endpoint,
                    filename: filename,
                    attempt: attempt + 1,
                    initialNetworkPathGeneration: initialNetworkPathGeneration,
                    usedNetworkPathBonusAttempt: usedNetworkPathBonusAttempt,
                    traceContext: traceContext,
                    traceDetails: traceDetails,
                    operation: operation,
                    completion: completion
                )
                return
            }

            let currentNetworkPathGeneration = self.currentGalleryNetworkPathGeneration()
            if isRetryable,
               !isSlotTimeoutFallback,
               !usedNetworkPathBonusAttempt,
               currentNetworkPathGeneration != initialNetworkPathGeneration {
                self.logMediaUploadTrace(
                    "gallery_\(endpoint.rawValue)_request_retry",
                    details: self.mediaUploadTraceDetails(
                        context: traceContext,
                        extra: traceDetails + [
                            ("endpoint", endpoint.rawValue),
                            ("filename", filename),
                            ("attempt", attemptContext.attempt),
                            ("nextAttempt", attempt + 1),
                            ("maxAttempts", self.galleryUploadMaxRetryAttempts),
                            ("traceID", attemptContext.traceID),
                            ("networkPathGeneration", attemptContext.networkPathGeneration),
                            ("networkPathGenerationNow", currentNetworkPathGeneration),
                            ("retryReason", "networkPathChanged")
                        ] + self.mediaUploadResponseTraceDetails(response)
                    )
                )
                self.performGalleryRequestWithRetry(
                    endpoint: endpoint,
                    filename: filename,
                    attempt: attempt + 1,
                    initialNetworkPathGeneration: initialNetworkPathGeneration,
                    usedNetworkPathBonusAttempt: true,
                    traceContext: traceContext,
                    traceDetails: traceDetails,
                    operation: operation,
                    completion: completion
                )
                return
            }

            let finalEvent = isSlotTimeoutFallback || !self.isGalleryFailureResponse(response)
                ? "gallery_\(endpoint.rawValue)_request_completed"
                : "gallery_\(endpoint.rawValue)_request_final_failure"
            self.logMediaUploadTrace(
                finalEvent,
                details: self.mediaUploadTraceDetails(
                    context: traceContext,
                    extra: traceDetails + [
                        ("endpoint", endpoint.rawValue),
                        ("filename", filename),
                        ("attempt", attemptContext.attempt),
                        ("maxAttempts", self.galleryUploadMaxRetryAttempts),
                        ("traceID", attemptContext.traceID),
                        ("networkPathGeneration", attemptContext.networkPathGeneration),
                        ("networkPathBonusAttempt", attemptContext.isNetworkPathBonusAttempt)
                    ] + self.mediaUploadResponseTraceDetails(response)
                )
            )
            completion(response)
        }
    }

    private func enqueueGallerySlotRequest(
        filename: String,
        traceContext: MediaUploadDiagnosticContext?,
        traceDetails: [(String, Any?)],
        start: @escaping (@escaping () -> Void) -> Void
    ) {
        let item = GallerySlotQueueItem(
            id: UUID().uuidString,
            filename: filename,
            traceContext: traceContext,
            traceDetails: traceDetails,
            start: start
        )
        let queueDepth: Int
        gallerySlotQueueLock.lock()
        gallerySlotQueue.append(item)
        queueDepth = gallerySlotQueue.count
        gallerySlotQueueLock.unlock()

        logMediaUploadTrace("gallery_slot_queue_enqueued", details: mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
            ("filename", filename),
            ("slotQueueID", item.id),
            ("queueDepth", queueDepth)
        ]))
        startNextGallerySlotRequestIfNeeded()
    }

    private func startNextGallerySlotRequestIfNeeded() {
        let item: GallerySlotQueueItem?
        let queueDepth: Int
        gallerySlotQueueLock.lock()
        if isGallerySlotRequestRunning || gallerySlotQueue.isEmpty {
            gallerySlotQueueLock.unlock()
            return
        }
        isGallerySlotRequestRunning = true
        item = gallerySlotQueue.removeFirst()
        queueDepth = gallerySlotQueue.count
        gallerySlotQueueLock.unlock()

        guard let item = item else { return }
        logMediaUploadTrace("gallery_slot_queue_started", details: mediaUploadTraceDetails(context: item.traceContext, extra: item.traceDetails + [
            ("filename", item.filename),
            ("slotQueueID", item.id),
            ("queueDepth", queueDepth)
        ]))
        item.start { [weak self] in
            self?.releaseGallerySlotRequest(item)
        }
    }

    private func releaseGallerySlotRequest(_ item: GallerySlotQueueItem) {
        let queueDepth: Int
        gallerySlotQueueLock.lock()
        isGallerySlotRequestRunning = false
        queueDepth = gallerySlotQueue.count
        gallerySlotQueueLock.unlock()

        logMediaUploadTrace("gallery_slot_queue_released", details: mediaUploadTraceDetails(context: item.traceContext, extra: item.traceDetails + [
            ("filename", item.filename),
            ("slotQueueID", item.id),
            ("queueDepth", queueDepth)
        ]))
        startNextGallerySlotRequestIfNeeded()
    }

    private func startGalleryNetworkPathMonitoring() {
        guard let monitor = Self.networkPathMonitorFactory() else {
            return
        }
        galleryNetworkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] snapshot in
            self?.handleGalleryNetworkPathSnapshot(snapshot)
        }
        monitor.start(queue: galleryNetworkPathQueue)
    }

    private func handleGalleryNetworkPathSnapshot(_ snapshot: AccountNetworkPathSnapshot) {
        let generation: Int
        let isInitial: Bool
        galleryNetworkPathLock.lock()
        if let currentSnapshot = galleryNetworkPathSnapshot {
            guard currentSnapshot != snapshot else {
                galleryNetworkPathLock.unlock()
                return
            }
            galleryNetworkPathGeneration += 1
            isInitial = false
        } else {
            isInitial = true
        }
        galleryNetworkPathSnapshot = snapshot
        generation = galleryNetworkPathGeneration
        galleryNetworkPathLock.unlock()

        logMediaUploadTrace("gallery_network_path_changed", details: [
            ("owner", owner),
            ("networkPathGeneration", generation),
            ("initial", isInitial)
        ] + galleryNetworkPathTraceDetails(snapshot))
    }

    private func currentGalleryNetworkPathGeneration() -> Int {
        galleryNetworkPathLock.lock()
        defer { galleryNetworkPathLock.unlock() }
        return galleryNetworkPathGeneration
    }

    private func currentGalleryNetworkPathTraceDetails() -> [(String, Any?)] {
        galleryNetworkPathLock.lock()
        let snapshot = galleryNetworkPathSnapshot
        galleryNetworkPathLock.unlock()
        return galleryNetworkPathTraceDetails(snapshot)
    }

    private func galleryNetworkPathTraceDetails(_ snapshot: AccountNetworkPathSnapshot?) -> [(String, Any?)] {
        guard let snapshot = snapshot else {
            return []
        }
        return [
            ("networkPathStatus", snapshot.status.rawValue),
            ("networkPathInterfaces", snapshot.interfaces.map { $0.rawValue }.sorted().joined(separator: ",")),
            ("networkPathExpensive", snapshot.isExpensive),
            ("networkPathConstrained", snapshot.isConstrained)
        ]
    }

    private func logMediaUploadTrace(_ event: String, details: [(String, Any?)] = []) {
        let renderedDetails = details.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(key)=\(mediaUploadTraceValue(value))"
        }.joined(separator: " ")
        let suffix = renderedDetails.isEmpty ? "" : " \(renderedDetails)"
        DDLogDebug("MEDIA_UPLOAD_TRACE event=\(event)\(suffix)")
    }

    private func mediaUploadTraceDetails(
        context: MediaUploadDiagnosticContext?,
        extra: [(String, Any?)] = []
    ) -> [(String, Any?)] {
        var seenKeys = Set<String>()
        return ([
            ("owner", owner),
            ("messagePrimary", context?.messagePrimary),
            ("referencePrimary", context?.referencePrimary)
        ] + extra).filter { key, _ in
            guard !seenKeys.contains(key) else { return false }
            seenKeys.insert(key)
            return true
        }
    }

    private func mediaUploadTraceValue(_ value: Any) -> String {
        let string = String(describing: value)
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard !string.isEmpty,
              string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "\"\(string)\""
        }
        return string
    }

    private func mediaUploadResponseTraceDetails(_ response: CloudStorageQuotaAPIResponse) -> [(String, Any?)] {
        switch response {
        case .response(let statusCode, let value, let diagnostics):
            let details: [(String, Any?)] = [
                ("statusCode", statusCode),
                ("serverStatus", int(from: (value as? NSDictionary)?["status"]) ?? int(from: (value as? [String: Any])?["status"]))
            ]
            return details + (diagnostics?.traceDetails() ?? [])
        case .failure(let statusCode, let error, let diagnostics):
            let nsError = mediaUploadNSError(error)
            let details: [(String, Any?)] = [
                ("statusCode", statusCode),
                ("errorDomain", nsError?.domain),
                ("errorCode", nsError?.code)
            ]
            return details + (diagnostics?.traceDetails() ?? [])
        }
    }

    private func mediaUploadNSError(_ error: Error?) -> NSError? {
        guard let error else {
            return nil
        }
        if let underlyingError = (error as? AFError)?.underlyingError {
            return mediaUploadNSError(underlyingError)
        }
        return error as NSError
    }

    private func isGalleryTimeoutResponse(_ response: CloudStorageQuotaAPIResponse) -> Bool {
        guard case .failure(_, let error, _) = response else {
            return false
        }
        return isGalleryTimeoutError(error)
    }

    private func isGalleryTimeoutError(_ error: Error?) -> Bool {
        guard let nsError = mediaUploadNSError(error) else {
            return false
        }
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func isGalleryFailureResponse(_ response: CloudStorageQuotaAPIResponse) -> Bool {
        switch response {
        case .response(let statusCode, _, _):
            guard let statusCode else { return true }
            return statusCode < 200 || statusCode >= 300
        case .failure:
            return true
        }
    }

    private func isRetryableGalleryResponse(_ response: CloudStorageQuotaAPIResponse) -> Bool {
        switch response {
        case .response(let statusCode, _, _):
            return isRetryableGalleryStatusCode(statusCode)
        case .failure(let statusCode, let error, _):
            return isRetryableGalleryStatusCode(statusCode) || isRetryableGalleryNetworkError(error)
        }
    }

    private func isRetryableGalleryStatusCode(_ statusCode: Int?) -> Bool {
        guard let statusCode else {
            return false
        }
        return statusCode == 408 || (500...599).contains(statusCode)
    }

    private func isRetryableGalleryNetworkError(_ error: Error?) -> Bool {
        guard let error else {
            return false
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed
           ].contains(nsError.code) {
            return true
        }

        if let underlyingError = (error as? AFError)?.underlyingError {
            return isRetryableGalleryNetworkError(underlyingError)
        }

        return false
    }

    private func refreshQuotaIfCurrent(_ context: CloudStorageGalleryRequestContext, reason: CloudStorageQuotaRefreshReason, force: Bool) {
        guard isCurrent(context) else { return }
        refreshQuota(reason: reason, force: force)
    }

    private struct GalleryTokenRequestTarget {
        let owner: String
        let galleryType: AccountGalleryType
        let baseURL: URL

        var identity: String {
            return AccountGalleryConfiguration.galleryIdentity(owner: owner, type: galleryType, url: baseURL)
        }

        init(owner: String, galleryType: AccountGalleryType, baseURL: URL) {
            self.owner = owner
            self.galleryType = galleryType
            self.baseURL = baseURL
        }

        init(context: CloudStorageGalleryRequestContext) {
            self.init(owner: context.owner, galleryType: context.galleryType, baseURL: context.baseURL)
        }
    }

    private func currentGalleryTokenTarget() -> GalleryTokenRequestTarget? {
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let baseURL = configuration.currentGalleryURL else {
            return nil
        }
        return GalleryTokenRequestTarget(owner: owner, galleryType: configuration.currentGalleryType, baseURL: baseURL)
    }

    private func tokenTarget(forConfirmURL rawURL: String?) -> GalleryTokenRequestTarget? {
        guard let baseURL = AccountGalleryConfiguration.galleryBaseURL(fromAuthURL: rawURL) else {
            return nil
        }
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard let galleryType = configuration.galleryType(for: baseURL) else {
            DDLogDebug("XabberUploadManager: \(#function). Unknown gallery auth URL: \(rawURL ?? "")")
            return nil
        }
        return GalleryTokenRequestTarget(owner: owner, galleryType: galleryType, baseURL: baseURL)
    }

    private func int(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    func uploadMedia(
        data: Data,
        filename: String,
        mimeType: String,
        metadata: [String: String]? = nil,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        guard let context = currentGalleryRequestContext() else {
            logMediaUploadTrace("gallery_upload_context_missing", details: [
                ("owner", owner),
                ("filename", filename)
            ])
            completion(.failure(statusCode: nil, error: UploadError.notAvailable))
            return
        }
        let traceDetails: [(String, Any?)] = [
            ("fileSize", data.count),
            ("mimeType", mimeType),
            ("galleryHost", context.baseURL.host)
        ]
        preflightUploadSlot(
            data: data,
            filename: filename,
            context: context,
            traceDetails: traceDetails,
            errorCallback: { _ in }
        ) { [weak self] shouldContinue in
            guard let self = self else { return }
            guard shouldContinue, self.isCurrent(context) else {
                self.logMediaUploadTrace("gallery_upload_aborted_after_slot", details: traceDetails + [
                    ("owner", self.owner),
                    ("filename", filename),
                    ("reason", shouldContinue ? "staleContext" : "slotRejected")
                ])
                completion(.failure(statusCode: 409, error: nil))
                return
            }
            let uploadContext = self.uploadContext(for: mimeType, metadata: metadata)
            let galleryMediaType = self.galleryMediaType(mimeType, context: uploadContext)
            self.performGalleryRequestWithRetry(
                endpoint: .upload,
                filename: filename,
                traceDetails: traceDetails + [
                    ("fileMimeType", mimeType),
                    ("galleryMediaType", galleryMediaType),
                    ("uploadContext", uploadContext)
                ],
                operation: { attemptContext, responseCompletion in
                    Self.quotaAPIClient.uploadFile(
                        baseURL: context.baseURL,
                        token: context.token,
                        data: data,
                        filename: filename,
                        fileMimeType: mimeType,
                        galleryMediaType: galleryMediaType,
                        metadata: metadata,
                        context: uploadContext,
                        traceID: attemptContext.traceID,
                        completion: responseCompletion
                    )
                },
                completion: completion
            )
        }
    }

    //MARK: - Uploads user's file on the server, receives file's and thumbnail's urls
    //MARK: - It is called in Account if the user doesn't have any token yet
    private func uploadFile(message primary: String, referencePrimary: String? = nil, data: Data, filename: String, mimeType: String? = nil, metadata: [String: String]? = nil, successCallback: @escaping ((String, String?, Int, String, String, URL, Int, Int) -> Void), failCallback: @escaping ((Error?) -> Void), errorCallback: @escaping ((Int?) -> Void)) {
        let traceContext = MediaUploadDiagnosticContext(messagePrimary: primary, referencePrimary: referencePrimary)
        guard let context = currentGalleryRequestContext() else {
            logMediaUploadTrace("gallery_upload_context_missing", details: mediaUploadTraceDetails(context: traceContext, extra: [
                ("filename", filename),
                ("fileSize", data.count),
                ("mimeType", mimeType)
            ]))
            failCallback(UploadError.notAvailable)
            return
        }

        guard let uploadURL = AccountGalleryConfiguration.apiURL(baseURL: context.baseURL, path: "v1/files/upload/") else {
            logMediaUploadTrace("gallery_upload_url_invalid", details: mediaUploadTraceDetails(context: traceContext, extra: [
                ("filename", filename),
                ("fileSize", data.count),
                ("mimeType", mimeType),
                ("galleryHost", context.baseURL.host)
            ]))
            errorCallback(nil)
            return
        }

        let traceDetails: [(String, Any?)] = [
            ("fileSize", data.count),
            ("mimeType", mimeType),
            ("galleryHost", context.baseURL.host)
        ]
        preflightUploadSlot(
            data: data,
            filename: filename,
            context: context,
            traceContext: traceContext,
            traceDetails: traceDetails,
            errorCallback: errorCallback
        ) { [weak self] shouldContinue in
            guard let self = self, shouldContinue else { return }
            guard self.isCurrent(context) else {
                self.logMediaUploadTrace("gallery_upload_context_stale", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                    ("filename", filename)
                ]))
                errorCallback(409)
                return
            }

            let uploadContext = self.uploadContext(for: mimeType, metadata: metadata)
            let fileMimeType = mimeType ?? ""
            let galleryMediaType = self.galleryMediaType(fileMimeType, context: uploadContext)

            self.performGalleryRequestWithRetry(
                endpoint: .upload,
                filename: filename,
                traceContext: traceContext,
                traceDetails: traceDetails + [
                    ("fileMimeType", fileMimeType),
                    ("galleryMediaType", galleryMediaType),
                    ("uploadContext", uploadContext)
                ],
                operation: { attemptContext, responseCompletion in
                    Self.quotaAPIClient.uploadFile(
                        baseURL: context.baseURL,
                        token: context.token,
                        data: data,
                        filename: filename,
                        fileMimeType: fileMimeType,
                        galleryMediaType: galleryMediaType,
                        metadata: metadata,
                        context: uploadContext,
                        traceID: attemptContext.traceID,
                        completion: responseCompletion
                    )
                }
            ) { [weak self] response in
                guard let self = self else { return }
                guard self.isCurrent(context) else {
                    errorCallback(409)
                    return
                }

                switch response {
                case .response(let code, let value, _):
                    guard let code = code else {
                        self.logMediaUploadTrace("gallery_upload_response_missing_status", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                            ("filename", filename)
                        ]))
                        errorCallback(nil)
                        return
                    }
                    if code >= 200 && code < 300 {
                        guard let json = value as? NSDictionary,
                              let fileUrl = json["file"] as? String,
                              let name = json["name"] as? String,
                              let hash = json["hash"] as? String,
                              let quota = self.int(from: json["quota"]),
                              let used = self.int(from: json["used"]),
                              let fileID = self.int(from: json["id"]) else {
                            let statusCode = self.int(from: (value as? NSDictionary)?["status"]) ?? code
                            self.logMediaUploadTrace("gallery_upload_response_invalid", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                                ("filename", filename),
                                ("statusCode", code),
                                ("serverStatus", statusCode)
                            ]))
                            errorCallback(statusCode)
                            return
                        }

                        let thumbnailUrl = (json["thumbnail"] as? NSDictionary)?["url"] as? String
                        self.logMediaUploadTrace("gallery_upload_response_parsed", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                            ("filename", filename),
                            ("statusCode", code),
                            ("fileID", fileID),
                            ("remoteFilename", name),
                            ("hashPrefix", String(hash.prefix(12))),
                            ("uploadHost", uploadURL.host),
                            ("quota", quota),
                            ("used", used)
                        ]))
                        successCallback(fileUrl, thumbnailUrl, fileID, name, hash, uploadURL, quota, used)
                        self.refreshQuotaIfCurrent(context, reason: .uploadCompleted, force: true)
                    } else {
                        if code == 401 {
                            self.tokenWasExpired(context)
                        }
                        let statusCode = self.int(from: (value as? NSDictionary)?["status"]) ?? code
                        if statusCode == 403 || code == 403 {
                            self.refreshQuotaIfCurrent(context, reason: .uploadQuotaExceeded, force: true)
                        }
                        self.logMediaUploadTrace("gallery_upload_status_rejected", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                            ("filename", filename),
                            ("statusCode", code),
                            ("serverStatus", statusCode)
                        ]))
                        errorCallback(statusCode)
                    }
                case .failure(let code, _, _):
                    self.logMediaUploadTrace("gallery_upload_network_failure", details: self.mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                        ("filename", filename),
                        ("statusCode", code)
                    ] + self.mediaUploadResponseTraceDetails(response)))
                    if code == 401 {
                        self.tokenWasExpired(context)
                    }
                    errorCallback(code)
                }
            }
        }
//        { result in
//                switch result {
//
//                case .success(request: let request, streamingFromDisk: let streamingFromDisk, streamFileURL: let streamFileURL):
//                    request.responseJSON(queue: nil, options: []) { response in
//                        guard let code = response.response?.statusCode else { return }
//                        if code >= 200 && code < 300 {
//                            guard let json = response.result.value as? NSDictionary,
//                                  let fileUrl = json["file"] as? String,
//                                  let name = json["name"] as? String,
//                                  let hash = json["hash"] as? String,
//                                  let quota = json["quota"] as? Int,
//                                  let used = json["used"] as? Int,
//                                  let fileID = json["id"] as? Int else {
//                                guard let json = response.result.value as? NSDictionary,
//                                      let statusCode = json["status"] as? Int else {
//                                          errorCallback(response.response?.statusCode)
//                                          return
//                                      }
//                                errorCallback(statusCode)
//                                return
//                            }
//
//                            let thumbnailUrl = (json["thumbnail"] as? NSDictionary)?["url"] as? String
//
//                            successCallback(fileUrl, thumbnailUrl, fileID, name, hash, url, quota, used)
//                            self.getStats()
//                        } else if code == 401 {
//                            self.tokenWasExpired()
//                            guard let json = response.result.value as? NSDictionary,
//                                  let statusCode = json["status"] as? Int else {
//                                      errorCallback(response.response?.statusCode)
//                                      return
//                                  }
//                            errorCallback(statusCode)
//                        } else if code > 401 {
//                            guard let json = response.result.value as? NSDictionary,
//                                  let statusCode = json["status"] as? Int else {
//                                      errorCallback(response.response?.statusCode)
//                                      return
//                                  }
//                            errorCallback(statusCode)
//                        }
//                    }
//
//                case .failure(let error):
//                    DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
//                    failCallback(error)
//                }
//            }
    }

    //MARK: - Gets voice & media references from sent message, calls uploadFile func
    //MARK: - and saves file's url on the server
    public func getFileData(message primary: String, successCallback: @escaping (() -> Void), failCallback: @escaping (() -> Void)) {
        var didFail = false

        func failOnce(_ message: String, code: Int? = nil) {
            guard !didFail else { return }
            didFail = true
            logMediaUploadTrace("message_upload_fail_once", details: [
                ("owner", owner),
                ("messagePrimary", primary),
                ("errorCode", code),
                ("reason", message)
            ])
            writeErrorInRealm(messageId: primary, errorText: message, errorCode: code)
            failCallback()
        }

        func callSuccessCallback() {
            do {
                let realm = try WRealm.safe()
                if realm.objects(MessageReferenceStorageItem.self)
                    .filter("owner == %@ AND messageId == %@ AND kind_ IN %@ AND isUploaded == false",
                            owner,
                            primary,
                            [MessageReferenceStorageItem.Kind.voice.rawValue, MessageReferenceStorageItem.Kind.media.rawValue])
                    .isEmpty {
                    logMediaUploadTrace("message_upload_all_references_uploaded", details: [
                        ("owner", owner),
                        ("messagePrimary", primary)
                    ])
                    clearUploadErrorInRealm(messageId: primary)
                    successCallback()
                }
            } catch {
                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            }
        }

        do {
            let realm = try WRealm.safe()
            let references = realm.objects(MessageReferenceStorageItem.self)
                .filter("owner == %@ AND messageId == %@ AND kind_ IN %@ AND isUploaded == false",
                        owner,
                        primary,
                            [MessageReferenceStorageItem.Kind.voice.rawValue, MessageReferenceStorageItem.Kind.media.rawValue])
            if references.isEmpty {
                logMediaUploadTrace("message_upload_no_pending_references", details: [
                    ("owner", owner),
                    ("messagePrimary", primary)
                ])
                clearUploadErrorInRealm(messageId: primary)
                successCallback()
                return
            }

            logMediaUploadTrace("message_upload_pending_references_found", details: [
                ("owner", owner),
                ("messagePrimary", primary),
                ("pendingReferenceCount", references.count)
            ])
            clearUploadErrorInRealm(messageId: primary)

            references.forEach { reference in
                guard !didFail else { return }
                do {
                    var metadata: [String: String]? = nil
                    let referencePrimary = reference.primary
                    let traceContext = MediaUploadDiagnosticContext(messagePrimary: primary, referencePrimary: referencePrimary)
                    logMediaUploadTrace("media_reference_prepare_started", details: mediaUploadTraceDetails(context: traceContext, extra: [
                        ("kind", reference.kind.rawValue),
                        ("mimeType", reference.mimeType),
                        ("isUploaded", reference.isUploaded),
                        ("hasLocalFile", reference.localFileUrl != nil)
                    ]))
                    guard let filename = reference.filename, filename.isNotEmpty else {
                        logMediaUploadTrace("media_reference_prepare_failed", details: mediaUploadTraceDetails(context: traceContext, extra: [
                            ("reason", "missingFilename")
                        ]))
                        failOnce("Selected file could not be prepared. Please choose it again.".localizeString(id: "upload_error_prepare_failed", arguments: []), code: 400)
                        return
                    }
                    guard let mediaType = reference.metadata?["media-type"] as? String, mediaType.isNotEmpty else {
                        logMediaUploadTrace("media_reference_prepare_failed", details: mediaUploadTraceDetails(context: traceContext, extra: [
                            ("filename", filename),
                            ("reason", "missingMediaType")
                        ]))
                        failOnce("Selected file has unsupported media metadata. Please choose it again.".localizeString(id: "upload_error_media_metadata", arguments: []), code: 400)
                        return
                    }

                    switch reference.mimeType {
                    case "image":
                        break
                    case "video":
                        metadata = [:]
                        metadata?["video_preview_key"] = reference.videoPreviewKey
                    case "voice", "audio":
                        metadata = [:]
                        metadata?["meters"] = reference.metadata?["meters"] as? String
                        metadata?["duration"] = reference.metadata?["duration"] as? String
                        if reference.localFileUrl == nil,
                           let url = reference.decodedUrl {
                            let unwrappedUrl = URL(fileURLWithPath: url.absoluteString)
                            try realm.write {
                                reference.localFileUrl = try? AudioMessageReceiver.shared.encode(url: unwrappedUrl)
                            }
                        }
                    default:
                        break
                    }

                    guard let localFileUrl = reference.localFileUrl else {
                        logMediaUploadTrace("media_reference_prepare_failed", details: mediaUploadTraceDetails(context: traceContext, extra: [
                            ("filename", filename),
                            ("mediaType", mediaType),
                            ("reason", "missingLocalFile")
                        ]))
                        failOnce("Selected file is unavailable. Please choose it again.".localizeString(id: "upload_error_local_file_unavailable", arguments: []), code: 400)
                        return
                    }

                    var data = try Data(contentsOf: localFileUrl as URL)
                    let encryptionKeyb64 = reference.metadata?["encryption-key"] as? String
                    let ivb64 = reference.metadata?["iv"] as? String
                    var encryptedFiles = false
                    if CommonConfigManager.shared.config.use_file_enryption_by_default,
                       reference.conversationType.isEncrypted {
                        guard let encryptionKeyb64 = encryptionKeyb64,
                              let ivb64 = ivb64 else {
                            logMediaUploadTrace("media_reference_prepare_failed", details: mediaUploadTraceDetails(context: traceContext, extra: [
                                ("filename", filename),
                                ("mediaType", mediaType),
                                ("fileSize", data.count),
                                ("reason", "missingEncryptionMetadata")
                            ]))
                            failOnce("Selected file could not be encrypted. Please try again.".localizeString(id: "upload_error_encryption_failed", arguments: []), code: 400)
                            return
                        }
                        let encryptionKey = Array<UInt8>(base64: encryptionKeyb64)
                        let iv = Array<UInt8>(base64: ivb64)
                        guard let encrypted = try data.encrypt(key: encryptionKey, iv: iv) else {
                            logMediaUploadTrace("media_reference_prepare_failed", details: mediaUploadTraceDetails(context: traceContext, extra: [
                                ("filename", filename),
                                ("mediaType", mediaType),
                                ("fileSize", data.count),
                                ("reason", "encryptionFailed")
                            ]))
                            failOnce("Selected file could not be encrypted. Please try again.".localizeString(id: "upload_error_encryption_failed", arguments: []), code: 400)
                            return
                        }

                        data = encrypted
                        encryptedFiles = true
                    }

                    logMediaUploadTrace("media_reference_prepared", details: mediaUploadTraceDetails(context: traceContext, extra: [
                        ("filename", filename),
                        ("mediaType", mediaType),
                        ("fileSize", data.count),
                        ("encrypted", encryptedFiles)
                    ]))
                    uploadFile(
                        message: primary,
                        referencePrimary: referencePrimary,
                        data: data,
                        filename: filename,
                        mimeType: mediaType,
                        metadata: metadata,
                        successCallback: { (getUrl, _, fileID, name, hash, uploadUrl, _, _) in
                            do {
                                let realm = try WRealm.safe()
                                if let uploadedReference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                                    try realm.write {
                                        uploadedReference.uploadUrl = uploadUrl
                                        uploadedReference.metadata?["uri"] = getUrl
                                        uploadedReference.metadata?["fileID"] = fileID
                                        uploadedReference.metadata?["filename"] = name
                                        uploadedReference.metadata?["hash"] = hash
                                        uploadedReference.isUploaded = true
                                        uploadedReference.url = getUrl
                                    }
                                }

                                self.logMediaUploadTrace("media_reference_uploaded", details: self.mediaUploadTraceDetails(context: traceContext, extra: [
                                    ("filename", filename),
                                    ("remoteFilename", name),
                                    ("fileID", fileID),
                                    ("hashPrefix", String(hash.prefix(12))),
                                    ("uploadHost", uploadUrl.host)
                                ]))
                                if encryptedFiles,
                                   let encryptionKeyb64 = encryptionKeyb64,
                                   let ivb64 = ivb64 {
                                    let encryptionKey = Array<UInt8>(base64: encryptionKeyb64)
                                    let iv = Array<UInt8>(base64: ivb64)
                                    if let decryptedData = try Data.decrypt(data, key: encryptionKey, iv: iv),
                                       let image = UIImage(data: decryptedData) {
                                        self.storeUploadedImageThumbnail(image: image, data: decryptedData, getUrl: getUrl, referencePrimary: referencePrimary)
                                    }
                                } else if let image = UIImage(data: data) {
                                    self.storeUploadedImageThumbnail(image: image, data: data, getUrl: getUrl, referencePrimary: referencePrimary)
                                }

                                callSuccessCallback()
                            } catch {
                                DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
                                failOnce("Upload finished, but the message could not be updated. Please try again.".localizeString(id: "upload_error_storage_update_failed", arguments: []), code: 500)
                            }
                        },
                        failCallback: { failError in
                            let nsError = self.mediaUploadNSError(failError)
                            self.logMediaUploadTrace("media_reference_upload_failed", details: self.mediaUploadTraceDetails(context: traceContext, extra: [
                                ("filename", filename),
                                ("errorDomain", nsError?.domain),
                                ("errorCode", nsError?.code)
                            ]))
                            failOnce("File upload failed. Please try again.".localizeString(id: "upload_error_failed", arguments: []), code: 500)
                        },
                        errorCallback: { errorCode in
                            guard !didFail else { return }
                            didFail = true
                            self.logMediaUploadTrace("media_reference_upload_error", details: self.mediaUploadTraceDetails(context: traceContext, extra: [
                                ("filename", filename),
                                ("errorCode", errorCode)
                            ]))
                            self.writeErrorInRealm(messageId: primary, errorCode: errorCode)
                            failCallback()
                        })
                } catch {
                    logMediaUploadTrace("media_reference_prepare_failed", details: [
                        ("owner", owner),
                        ("messagePrimary", primary),
                        ("errorType", String(describing: type(of: error)))
                    ])
                    failOnce("Selected file is unavailable. Please choose it again.".localizeString(id: "upload_error_local_file_unavailable", arguments: []), code: 400)
                }
            }
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            failOnce("Selected file could not be prepared. Please choose it again.".localizeString(id: "upload_error_prepare_failed", arguments: []), code: 400)
        }
    }

    private func storeUploadedImageThumbnail(image: UIImage, data: Data, getUrl: String, referencePrimary: String) {
        do {
            ImageCache.default.storeToDisk(data, forKey: getUrl)
            let thumb = image.resize(targetSize: CGSize(square: 24))
            guard let b64Thumb = thumb.jpegData(compressionQuality: 0.5)?.base64EncodedString() else {
                return
            }
            let realm = try WRealm.safe()
            if let uploadedReference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: referencePrimary) {
                try realm.write {
                    uploadedReference.metadata?["thumbnail-height"] = thumb.size.height
                    uploadedReference.metadata?["thumbnail-width"] = thumb.size.width
                    uploadedReference.metadata?["thumbnail-uri"] = "data:image/jpeg;base64,\(b64Thumb)"
                }
            }
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func clearUploadErrorInRealm(messageId: String) {
        do {
            let realm = try WRealm.safe()
            if let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: messageId) {
                try realm.write {
                    if message.isInvalidated { return }
                    message.messageError = nil
                    message.messageErrorCode = nil
                    message.references.forEach {
                        $0.hasError = false
                    }
                }
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }

    //MARK: - Prepares information for error info view
    //MARK: - messageId is primary: it already contains owner
    private func writeErrorInRealm(messageId: String, errorCode: Int? = nil) {
        var errorText = "Undefined upload error".localizeString(id: "upload_error_undefined", arguments: [])
        switch errorCode {
        case 400: errorText = "No file attached".localizeString(id: "upload_error_no_attach", arguments: [])
        case 401: errorText = "Incorrect token: unauthorized by server".localizeString(id: "upload_error_incorrect_token", arguments: [])
        case 403: errorText = "Quota exceeded".localizeString(id: "upload_error_quota_exceeded", arguments: [])
        case 413: errorText = "File is too large".localizeString(id: "upload_error_file_too_large", arguments: [])
        case 502: errorText = "Bad gateway: server error (502)".localizeString(id: "upload_error_bad_gateway", arguments: [])
        case 503: errorText = "Server unavailable".localizeString(id: "upload_error_server_unavailable", arguments: [])
        default: errorText = "Undefined upload error".localizeString(id: "upload_error_undefined", arguments: [])
        }

        writeErrorInRealm(messageId: messageId, errorText: errorText, errorCode: errorCode)
    }

    private func writeErrorInRealm(messageId: String, errorText: String, errorCode: Int? = nil) {

        do {
            let realm = try WRealm.safe()
            if let message = realm
                .object(ofType: MessageStorageItem.self,
                        forPrimaryKey: messageId) {
                let owner = message.owner
                let conversationType = message.conversationType
                let referenceCount = message.references.count
                try realm.write {
                    if message.isInvalidated { return }
                    message.messageError = errorText
                    message.messageErrorCode = "\(errorCode ?? 500)"
                    message.state = .error
                    message.references.forEach({
                        $0.hasError = true
                    })
                    realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: message.opponent, owner: message.owner, conversationType: message.conversationType))?.hasErrorInChat = true
                }
                logMediaUploadTrace("message_upload_error_written", details: [
                    ("owner", owner),
                    ("messagePrimary", messageId),
                    ("conversationType", conversationType.rawValue),
                    ("referenceCount", referenceCount),
                    ("messageErrorCode", errorCode ?? 500),
                    ("state", "error")
                ])
            }
        } catch {
            DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
        }
    }

    //MARK: - Receives quota info, file types' stats and writes it in realm
    public func getStats(_ callback: (() -> Void)? = nil) {
        refreshQuota(reason: .manual, force: false) { _ in
            callback?()
        }
    }

    public func refreshQuota(
        reason: CloudStorageQuotaRefreshReason = .manual,
        force: Bool = false,
        completion: ((CloudStorageQuotaRefreshResult) -> Void)? = nil
    ) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            let result: CloudStorageQuotaRefreshResult
            switch availabilityRelay.value {
            case .discovering, .authorizing:
                result = .pending
            case .unsupported:
                result = .unavailable
            case .retryableFailure(let stage, _):
                switch stage {
                case .discovery, .authorization, .disconnected:
                    result = .pending
                case .quota:
                    result = .failure
                }
            case .ready:
                markAvailabilityRetryableFailure(stage: .quota)
                result = .failure
            }
            completion?(result)
            postQuotaRefreshDidFinish(reason: reason, result: result)
            return
        }

        guard let generation = beginQuotaRefresh(context: context, completion: completion) else {
            return
        }

        postQuotaRefreshDidStart(reason: reason, context: context)
        fetchStatsAndStoreQuota(context: context, generation: generation, reason: reason)
    }

    private func fetchStatsAndStoreQuota(
        context: CloudStorageGalleryRequestContext,
        generation: Int,
        reason: CloudStorageQuotaRefreshReason
    ) {
        Self.quotaAPIClient.getStats(baseURL: context.baseURL, token: context.token) { [weak self] response in
            guard let self = self else { return }
            guard self.isCurrentQuotaRefresh(generation: generation, context: context) else { return }
            guard self.currentGalleryRequestContext() == context else {
                self.finishQuotaRefresh(
                    generation: generation,
                    context: context,
                    reason: reason,
                    result: .pending
                )
                return
            }

            switch response {
            case .response(let code, let value, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .unauthorized)
                } else if let code = code, code >= 200 && code < 300, let value = value, let payload = CloudStorageQuotaStatsPayload.parse(value) {
                    let result: CloudStorageQuotaRefreshResult = self.storeQuota(statsPayload: payload, context: context) ? .success : .failure
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: result)
                } else {
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .failure)
                }

            case .failure(let code, let error, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .unauthorized)
                } else {
                    DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .failure)
                }
            }
        }
    }

    @discardableResult
    private func storeQuota(
        statsPayload payload: CloudStorageQuotaStatsPayload,
        context: CloudStorageGalleryRequestContext
    ) -> Bool {
        guard currentGalleryRequestContext() == context else {
            return false
        }
        do {
            let realm = try WRealm.safe()
            let primary = AccountQuotaStorageItem.genPrimary(jid: owner)
            let item = realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: primary) ?? AccountQuotaStorageItem()
            let isNew = item.primary.isEmpty
            let shouldResetMissingCategories = isNew
                || !AccountGalleryConfiguration(owner: owner).cachedQuotaMatches(
                    galleryType: context.galleryType,
                    galleryURL: context.baseURL
                )
            if isNew {
                item.primary = primary
                item.jid = owner
            }

            try realm.write {
                item.quotaBytes = payload.quota
                item.totalBytes = payload.total.used
                item.totalCount = payload.total.count
                self.apply(payload.images, bytes: \.imagesBytes, count: \.imagesCount, to: item, resetIfMissing: shouldResetMissingCategories)
                self.apply(payload.videos, bytes: \.videosBytes, count: \.videosCount, to: item, resetIfMissing: shouldResetMissingCategories)
                self.apply(payload.files, bytes: \.filesBytes, count: \.filesCount, to: item, resetIfMissing: shouldResetMissingCategories)
                self.apply(payload.audio, bytes: \.audioBytes, count: \.audioCount, to: item, resetIfMissing: shouldResetMissingCategories)
                self.apply(payload.voices, bytes: \.voicesBytes, count: \.voicesCount, to: item, resetIfMissing: shouldResetMissingCategories)
                self.apply(payload.avatars, bytes: \.avatarsBytes, count: \.avatarsCount, to: item, resetIfMissing: shouldResetMissingCategories)
                if isNew {
                    realm.add(item, update: .modified)
                }
            }
            AccountGalleryConfiguration(owner: owner).markQuotaStored(galleryType: context.galleryType, galleryURL: context.baseURL)
            return true
        } catch {
            DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func apply(
        _ category: CloudStorageQuotaCategory?,
        bytes: ReferenceWritableKeyPath<AccountQuotaStorageItem, Int>,
        count: ReferenceWritableKeyPath<AccountQuotaStorageItem, Int>,
        to item: AccountQuotaStorageItem,
        resetIfMissing: Bool
    ) {
        guard let category else {
            if resetIfMissing {
                item[keyPath: bytes] = 0
                item[keyPath: count] = 0
            }
            return
        }
        item[keyPath: bytes] = category.used
        item[keyPath: count] = category.count
    }

    private func beginQuotaRefresh(
        context: CloudStorageGalleryRequestContext,
        completion: ((CloudStorageQuotaRefreshResult) -> Void)?
    ) -> Int? {
        quotaRefreshLock.lock()
        if isQuotaRefreshInFlight,
           quotaRefreshInFlightContext == context {
            if let completion = completion {
                quotaRefreshCallbacks.append(completion)
            }
            quotaRefreshLock.unlock()
            return nil
        }

        let supersededCallbacks = isQuotaRefreshInFlight ? quotaRefreshCallbacks : []
        quotaRefreshGeneration += 1
        isQuotaRefreshInFlight = true
        quotaRefreshInFlightContext = context
        quotaRefreshCallbacks = completion.map { [$0] } ?? []
        let generation = quotaRefreshGeneration
        quotaRefreshLock.unlock()

        supersededCallbacks.forEach { $0(.pending) }
        return generation
    }

    private func isCurrentQuotaRefresh(generation: Int, context: CloudStorageGalleryRequestContext) -> Bool {
        quotaRefreshLock.lock()
        let isCurrentGeneration = isQuotaRefreshInFlight
            && quotaRefreshGeneration == generation
            && quotaRefreshInFlightContext == context
        quotaRefreshLock.unlock()
        return isCurrentGeneration
    }

    private func finishQuotaRefresh(
        generation: Int,
        context: CloudStorageGalleryRequestContext,
        reason: CloudStorageQuotaRefreshReason,
        result: CloudStorageQuotaRefreshResult
    ) {
        quotaRefreshLock.lock()
        guard isQuotaRefreshInFlight,
              quotaRefreshGeneration == generation,
              quotaRefreshInFlightContext == context else {
            quotaRefreshLock.unlock()
            return
        }
        let callbacks = quotaRefreshCallbacks
        quotaRefreshCallbacks = []
        isQuotaRefreshInFlight = false
        quotaRefreshInFlightContext = nil
        quotaRefreshLock.unlock()

        let deliveredResult: CloudStorageQuotaRefreshResult
        if result == .unauthorized || currentGalleryRequestContext() == context {
            deliveredResult = result
        } else {
            deliveredResult = .pending
        }

        // Quota freshness is independent from Cloud operational readiness.
        // A timeout, 5xx, or malformed stats payload does not invalidate the
        // already-scoped endpoint/token pair, and a stale success must not
        // overwrite a disconnected availability state. HTTP 401 is handled
        // above by tokenWasExpired(_:) and starts scoped reauthorization.
        postQuotaRefreshDidFinish(reason: reason, result: deliveredResult, context: context)
        callbacks.forEach { $0(deliveredResult) }
    }

    private func postQuotaRefreshDidStart(reason: CloudStorageQuotaRefreshReason, context: CloudStorageGalleryRequestContext) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cloudStorageQuotaRefreshDidStart,
                object: self,
                userInfo: [
                    "jid": self.owner,
                    "reason": reason.rawValue,
                    "galleryType": context.galleryType.rawValue,
                    "galleryURL": context.baseURL.absoluteString,
                    "galleryIdentity": context.identity
                ]
            )
        }
    }

    private func postQuotaRefreshDidFinish(
        reason: CloudStorageQuotaRefreshReason,
        result: CloudStorageQuotaRefreshResult,
        context: CloudStorageGalleryRequestContext? = nil
    ) {
        DispatchQueue.main.async {
            var userInfo: [String: String] = [
                "jid": self.owner,
                "reason": reason.rawValue,
                "result": result.rawValue
            ]
            if let context = context {
                userInfo["galleryType"] = context.galleryType.rawValue
                userInfo["galleryURL"] = context.baseURL.absoluteString
                userInfo["galleryIdentity"] = context.identity
            }
            NotificationCenter.default.post(name: .cloudStorageQuotaRefreshDidFinish, object: self, userInfo: userInfo)
        }
    }

    func preflightUploadSlot(
        data: Data,
        filename: String,
        context providedContext: CloudStorageGalleryRequestContext? = nil,
        traceContext: MediaUploadDiagnosticContext? = nil,
        traceDetails: [(String, Any?)] = [],
        errorCallback: @escaping ((Int?) -> Void),
        completion: @escaping (Bool) -> Void
    ) {
        guard let context = providedContext ?? currentGalleryRequestContext() else {
            logMediaUploadTrace("gallery_slot_preflight_skipped", details: mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                ("filename", filename),
                ("fileSize", data.count),
                ("reason", "missingGalleryContext")
            ]))
            logMediaUploadTrace("gallery_slot_queue_skipped", details: mediaUploadTraceDetails(context: traceContext, extra: traceDetails + [
                ("filename", filename),
                ("fileSize", data.count),
                ("reason", "missingGalleryContext")
            ]))
            completion(true)
            return
        }

        let hash = data.sha256Data.hexEncodedString()
        let request = CloudStorageUploadSlotRequest(
            size: data.count,
            name: filename,
            hash: hash
        )
        let slotTraceDetails = traceDetails + [
            ("filename", filename),
            ("fileSize", data.count),
            ("hashPrefix", String(hash.prefix(12))),
            ("galleryHost", context.baseURL.host)
        ]

        enqueueGallerySlotRequest(
            filename: filename,
            traceContext: traceContext,
            traceDetails: slotTraceDetails
        ) { [weak self] releaseSlot in
            guard let self = self else {
                releaseSlot()
                completion(false)
                return
            }
            self.performGalleryRequestWithRetry(
                endpoint: .slot,
                filename: filename,
                traceContext: traceContext,
                traceDetails: slotTraceDetails,
                operation: { attemptContext, responseCompletion in
                    Self.quotaAPIClient.requestSlot(
                        baseURL: context.baseURL,
                        token: context.token,
                        request: request,
                        traceID: attemptContext.traceID,
                        timeoutInterval: self.gallerySlotRequestTimeout,
                        completion: responseCompletion
                    )
                }
            ) { [weak self] response in
                releaseSlot()
                guard let self = self else { return }
                guard self.isCurrent(context) else {
                    self.logMediaUploadTrace("gallery_slot_preflight_rejected", details: self.mediaUploadTraceDetails(context: traceContext, extra: slotTraceDetails + [
                        ("reason", "staleContext")
                    ]))
                    completion(false)
                    return
                }

                let code: Int?
                switch response {
                case .response(let statusCode, _, _):
                    code = statusCode
                case .failure(let statusCode, _, _):
                    code = statusCode
                }

                if self.isGalleryTimeoutResponse(response) {
                    self.logMediaUploadTrace("gallery_slot_timeout_upload_fallback", details: self.mediaUploadTraceDetails(context: traceContext, extra: slotTraceDetails + [
                        ("timeout", self.gallerySlotRequestTimeout),
                        ("statusCode", code)
                    ] + self.mediaUploadResponseTraceDetails(response)))
                    completion(true)
                } else if code == 403 {
                    self.logMediaUploadTrace("gallery_slot_preflight_rejected", details: self.mediaUploadTraceDetails(context: traceContext, extra: slotTraceDetails + [
                        ("reason", "quotaExceeded"),
                        ("statusCode", code)
                    ]))
                    errorCallback(403)
                    self.refreshQuotaIfCurrent(context, reason: .uploadQuotaExceeded, force: true)
                    completion(false)
                } else if self.isRetryableGalleryResponse(response) {
                    self.logMediaUploadTrace("gallery_slot_preflight_rejected", details: self.mediaUploadTraceDetails(context: traceContext, extra: slotTraceDetails + [
                        ("reason", "retryExhausted"),
                        ("statusCode", code)
                    ] + self.mediaUploadResponseTraceDetails(response)))
                    errorCallback(code)
                    completion(false)
                } else {
                    if code == 401 {
                        self.tokenWasExpired(context)
                    }
                    self.logMediaUploadTrace("gallery_slot_preflight_passed", details: self.mediaUploadTraceDetails(context: traceContext, extra: slotTraceDetails + [
                        ("statusCode", code)
                    ]))
                    completion(true)
                }
            }
        }
    }

    //MARK: - Deletes one media file with selected id
    public func deleteMediaFromServer(fileID: Int) {
        deleteFile(fileID: fileID, isAvatar: false) { result in
            if case .failure(let error) = result {
                DDLogDebug("XabberUploadManager: \(#function). \(error)")
            }
        }
    }


    final func handleUnauthorized(context: CloudStorageGalleryRequestContext) {
        tokenWasExpired(context)
    }

    private final func tokenWasExpired(_ context: CloudStorageGalleryRequestContext) {
        if let handler = Self.tokenExpiredTestingHandler {
            handler(context)
            return
        }
        let configuration = AccountGalleryConfiguration(owner: owner)
        guard configuration.currentGalleryIdentity == context.identity else {
            return
        }
        let currentToken = configuration.token(
            for: context.galleryType,
            baseURL: context.baseURL
        )
        guard currentToken.isEmpty || currentToken == context.token else {
            DDLogDebug(
                "CLOUD_AVAILABILITY ignoredStaleUnauthorized=true tokenRotated=true endpointKnown=true"
            )
            noteTokenResolved(
                galleryType: context.galleryType,
                endpoint: context.baseURL
            )
            return
        }
        if currentToken == context.token {
            configuration.clearToken(
                galleryType: context.galleryType,
                baseURL: context.baseURL
            )
        }
        requestAuthIfNeeded(galleryType: context.galleryType, baseURL: context.baseURL)
    }

    static let supportedCleanupPercents: Set<Int> = [25, 50, 75]

    struct CloudStorageCleanupPlan: Equatable {
        let percent: Int
        let context: CloudStorageGalleryRequestContext

        fileprivate init(percent: Int, context: CloudStorageGalleryRequestContext) {
            self.percent = percent
            self.context = context
        }
    }

    private final class CompletionOnce {
        private let lock = NSLock()
        private var isCompleted = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }
    }

    private struct PagePayload {
        let items: [NSDictionary]
        let totalObjects: Int
        let objPerPage: Int
        let totalPages: Int
    }

    private func pagePayload(from json: NSDictionary) -> PagePayload? {
        let rawItems = json["items"] ?? json["results"]
        let items: [NSDictionary]
        if let dictionaries = rawItems as? [NSDictionary] {
            items = dictionaries
        } else if let dictionaries = rawItems as? [[String: Any]] {
            items = dictionaries.map { $0 as NSDictionary }
        } else {
            return nil
        }

        let totalObjects = int(from: json["total_objects"] ?? json["count"]) ?? items.count
        let objPerPage = int(from: json["obj_per_page"]) ?? max(items.count, 1)
        guard totalObjects >= 0, objPerPage > 0 else { return nil }

        let declaredTotalPages = int(from: json["total_pages"])
        if let declaredTotalPages, declaredTotalPages < 0 { return nil }
        let calculatedTotalPages = totalObjects == 0
            ? 1
            : ((totalObjects - 1) / objPerPage) + 1
        let totalPages = max(1, declaredTotalPages ?? calculatedTotalPages)
        return PagePayload(
            items: items,
            totalObjects: totalObjects,
            objPerPage: objPerPage,
            totalPages: totalPages
        )
    }

    private func fullContextIsCurrent(_ context: CloudStorageGalleryRequestContext) -> Bool {
        return currentGalleryRequestContext() == context
    }

    private func listPageResult(
        from response: CloudStorageQuotaAPIResponse,
        context: CloudStorageGalleryRequestContext,
        requestedPage: Int
    ) -> Result<CloudStorageListPage, CloudStorageListLoadError> {
        guard fullContextIsCurrent(context) else {
            return .failure(.staleSelection)
        }

        switch response {
        case .response(let statusCode, let value, _):
            if statusCode == 401 {
                tokenWasExpired(context)
                return .failure(.unauthorized)
            }
            guard let statusCode else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(statusCode) else {
                return .failure(.server(statusCode: statusCode))
            }
            guard requestedPage > 0,
                  let json = value as? NSDictionary,
                  let payload = pagePayload(from: json) else {
                return .failure(.invalidResponse)
            }
            return .success(CloudStorageListPage(
                items: payload.items,
                totalObjects: payload.totalObjects,
                objectsPerPage: payload.objPerPage,
                totalPages: payload.totalPages,
                page: requestedPage
            ))

        case .failure(let statusCode, let error, _):
            if statusCode == 401 {
                tokenWasExpired(context)
                return .failure(.unauthorized)
            }
            if let statusCode {
                if (200..<300).contains(statusCode) {
                    return .failure(.invalidResponse)
                }
                return .failure(.server(statusCode: statusCode))
            }
            DDLogDebug("XabberUploadManager: cloud storage list failed. \(error?.localizedDescription ?? "Unknown error")")
            return .failure(.transport)
        }
    }

    private func mutationResult(
        from response: CloudStorageQuotaAPIResponse,
        context: CloudStorageGalleryRequestContext
    ) -> Result<Void, CloudStorageListLoadError> {
        guard fullContextIsCurrent(context) else {
            return .failure(.staleSelection)
        }

        switch response {
        case .response(let statusCode, _, _):
            if statusCode == 401 {
                tokenWasExpired(context)
                return .failure(.unauthorized)
            }
            guard let statusCode else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(statusCode) else {
                return .failure(.server(statusCode: statusCode))
            }
            return .success(())

        case .failure(let statusCode, let error, _):
            if statusCode == 401 {
                tokenWasExpired(context)
                return .failure(.unauthorized)
            }
            if let statusCode {
                if (200..<300).contains(statusCode) {
                    return .failure(.invalidResponse)
                }
                return .failure(.server(statusCode: statusCode))
            }
            DDLogDebug("XabberUploadManager: cloud storage delete failed. \(error?.localizedDescription ?? "Unknown error")")
            return .failure(.transport)
        }
    }

    //MARK: - Deletes avatar with selected id
    public func deleteAvatarFromServer(fileID: Int) {
        deleteFile(fileID: fileID, isAvatar: true) { result in
            if case .failure(let error) = result {
                DDLogDebug("XabberUploadManager: \(#function). \(error)")
            }
        }
    }

    public func deleteGallery(jid: String) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.deleteGallery(baseURL: context.baseURL, token: context.token, jid: jid) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, _, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                }
            case .failure(let code, let error, _):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
        }
    }

    func getFilesPage(
        type: MimeIconTypes,
        page: Int,
        completion: @escaping (Result<CloudStorageListPage, CloudStorageListLoadError>) -> Void
    ) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            completion(.failure(.unavailable))
            return
        }
        let once = CompletionOnce()

        Self.quotaAPIClient.getFiles(baseURL: context.baseURL, token: context.token, type: type, page: page) { [weak self] response in
            guard once.claim() else { return }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            completion(self.listPageResult(from: response, context: context, requestedPage: page))
        }
    }

    func getAvatarsPage(
        page: Int,
        completion: @escaping (Result<CloudStorageListPage, CloudStorageListLoadError>) -> Void
    ) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            completion(.failure(.unavailable))
            return
        }
        let once = CompletionOnce()

        Self.quotaAPIClient.getAvatars(baseURL: context.baseURL, token: context.token, page: page) { [weak self] response in
            guard once.claim() else { return }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            completion(self.listPageResult(from: response, context: context, requestedPage: page))
        }
    }

    func makeCleanupPlan(
        percent: Int
    ) -> Result<CloudStorageCleanupPlan, CloudStorageListLoadError> {
        guard Self.supportedCleanupPercents.contains(percent) else {
            return .failure(.invalidResponse)
        }
        guard let context = currentGalleryRequestContext() else {
            return .failure(.unavailable)
        }
        return .success(CloudStorageCleanupPlan(percent: percent, context: context))
    }

    func getFilesToDelete(
        plan: CloudStorageCleanupPlan,
        page: Int,
        completion: @escaping (Result<CloudStorageListPage, CloudStorageListLoadError>) -> Void
    ) {
        guard Self.supportedCleanupPercents.contains(plan.percent) else {
            completion(.failure(.invalidResponse))
            return
        }
        guard plan.context.owner == owner else {
            completion(.failure(.staleSelection))
            return
        }
        guard fullContextIsCurrent(plan.context) else {
            completion(.failure(.staleSelection))
            return
        }
        let once = CompletionOnce()

        Self.quotaAPIClient.getFilesToDelete(
            baseURL: plan.context.baseURL,
            token: plan.context.token,
            percent: plan.percent,
            page: page
        ) { [weak self] response in
            guard once.claim() else { return }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            completion(self.listPageResult(from: response, context: plan.context, requestedPage: page))
        }
    }

    func deleteMedia(
        using plan: CloudStorageCleanupPlan,
        completion: @escaping (Result<Void, CloudStorageListLoadError>) -> Void
    ) {
        guard Self.supportedCleanupPercents.contains(plan.percent) else {
            completion(.failure(.invalidResponse))
            return
        }
        guard plan.context.owner == owner, fullContextIsCurrent(plan.context) else {
            completion(.failure(.staleSelection))
            return
        }
        let once = CompletionOnce()

        Self.quotaAPIClient.deleteMediaFor(
            baseURL: plan.context.baseURL,
            token: plan.context.token,
            percent: plan.percent
        ) { [weak self] response in
            guard once.claim() else { return }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            let result = self.mutationResult(from: response, context: plan.context)
            if case .success = result {
                self.refreshQuotaIfCurrent(plan.context, reason: .manual, force: true)
            }
            completion(result)
        }
    }

    func deleteFile(
        fileID: Int,
        isAvatar: Bool,
        completion: @escaping (Result<Void, CloudStorageListLoadError>) -> Void
    ) {
        guard let context = currentGalleryRequestContext() else {
            completion(.failure(.unavailable))
            return
        }
        let once = CompletionOnce()
        let responseHandler: (CloudStorageQuotaAPIResponse) -> Void = { [weak self] response in
            guard once.claim() else { return }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            let result = self.mutationResult(from: response, context: context)
            if case .success = result {
                self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
            }
            completion(result)
        }

        if isAvatar {
            Self.quotaAPIClient.deleteAvatar(
                baseURL: context.baseURL,
                token: context.token,
                fileID: fileID,
                completion: responseHandler
            )
        } else {
            Self.quotaAPIClient.deleteMedia(
                baseURL: context.baseURL,
                token: context.token,
                fileID: fileID,
                completion: responseHandler
            )
        }
    }

    func getFilesOfType(type: MimeIconTypes, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        getFilesPage(type: type, page: page) { result in
            guard case .success(let page) = result else { return }
            callback(page.items, page.totalObjects, page.objectsPerPage, page.totalPages)
        }
    }

    func getAvatars(page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        getAvatarsPage(page: page) { result in
            guard case .success(let page) = result else { return }
            callback(page.items, page.totalObjects, page.objectsPerPage, page.totalPages)
        }
    }

    func getFilesToDeleteByPercent(percent: Int, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard case .success(let plan) = makeCleanupPlan(percent: percent) else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        getFilesToDelete(plan: plan, page: page) { result in
            guard case .success(let page) = result else { return }
            callback(page.items, page.totalObjects, page.objectsPerPage, page.totalPages)
        }
    }

    //MARK: - Deletes all media files for selected period
    public func deleteMediaFor(percent: Int, callback: (() -> Void)?) {
        guard case .success(let plan) = makeCleanupPlan(percent: percent) else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }
        deleteMedia(using: plan) { result in
            switch result {
            case .success:
                callback?()
            case .failure(let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error)")
            }
        }
    }

    enum FilesContext: String {
        case avatar = "avatar"
        case file = "file"
        case voice = "voice"
    }

    public func deleteMediaForAll(callback: (() -> Void)?) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.deleteMediaForAll(baseURL: context.baseURL, token: context.token) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, _, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                } else {
                    self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
                }
            case .failure(let code, let error, _):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
            callback?()
        }
    }

    public final func enable() {
        guard let target = currentGalleryTokenTarget() else {
            return
        }
        requestAuthIfNeeded(galleryType: target.galleryType, baseURL: target.baseURL)
    }

    final func requestAuthIfNeeded(galleryType: AccountGalleryType, baseURL: URL) {
        let configuration = AccountGalleryConfiguration(owner: owner)
        let target = GalleryTokenRequestTarget(owner: owner, galleryType: galleryType, baseURL: baseURL)
        let selectedIdentity = configuration.currentGalleryIdentity
        guard configuration.token(for: galleryType, baseURL: baseURL).isEmpty else {
            noteTokenResolved(galleryType: galleryType, endpoint: baseURL)
            return
        }
        if selectedIdentity == target.identity {
            publishAvailability(.authorizing(endpoint: baseURL))
        }
        guard let stream = AccountManager.shared.find(for: self.owner)?.xmppStream else {
            DDLogDebug(
                "CLOUD_AVAILABILITY authorizationDeferred=true accountRegistered=false endpointKnown=true"
            )
            return
        }
        guard let fulljid = stream.myJID?.full else {
            if selectedIdentity == target.identity {
                publishAvailability(
                    .retryableFailure(stage: .authorization, endpoint: baseURL)
                )
            }
            DDLogDebug(
                "CLOUD_AVAILABILITY authorizationDeferred=true boundJID=false endpointKnown=true"
            )
            return
        }
        guard let generation = beginAuthorization(
            target: target,
            selectedIdentity: selectedIdentity
        ) else {
            return
        }
        getCode(fullJID: fulljid, target: target, generation: generation)
    }

    //MARK: - Sends inquiry to the server in order to get non-permanent code
    private func getCode(
        fullJID: String,
        target: GalleryTokenRequestTarget,
        generation: Int,
        failCallback: ((String?) -> Void)? = nil
    ) {
        Self.tokenAPIClient.requestCode(baseURL: target.baseURL, fullJID: fullJID) { [weak self] response in
            guard let self = self,
                  self.isCurrentAuthorization(identity: target.identity, generation: generation) else {
                return
            }
            switch response {
            case .response(let code, _, _):
                DDLogDebug(
                    "CLOUD_AVAILABILITY authorizationCodeResponse=true statusCode=\(code ?? -1)"
                )
                if let code = code, code >= 200 && code < 300 {
                    DDLogDebug("CLOUD_AVAILABILITY authorizationCodeRequested=true")
                } else {
                    failCallback?(nil)
                    self.failAuthorization(target: target, generation: generation)
                }
            case .failure(let code, let error, _):
                let errorCode = (error as NSError?)?.code ?? 0
                DDLogDebug(
                    "CLOUD_AVAILABILITY authorizationCodeFailure=true statusCode=\(code ?? -1) errorCode=\(errorCode)"
                )
                failCallback?(error?.localizedDescription)
                self.failAuthorization(target: target, generation: generation)
                DDLogDebug(error?.localizedDescription ?? "Unknown error")
            }
        }
    }


    //MARK: - Function is called in AccountStremDelegate and gets iq received from the server
    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case parseCodeFromStanza(withIQ: iq): return true
        default: return false
        }
    }



    //MARK: - Parses non-permanent code from received stanza; non-permanent code is active for 1 minute
    private func parseCodeFromStanza(withIQ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .get,
              let confirm = iq.element(
                forName: "confirm",
                xmlns: XabberUploadManager.httpAuthNamespace
              ),
              let code = confirm.attributeStringValue(forName: "id"),
              let target = tokenTarget(forConfirmURL: confirm.attributeStringValue(forName: "url")) else {
                return false
              }
        guard let generation = beginTokenExchange(target: target) else {
            DDLogDebug("CLOUD_AVAILABILITY ignoredStaleTokenConfirmation=true")
            return true
        }
        getToken(withCode: code, target: target, generation: generation, failCallback: nil)
        return true
    }


    //MARK: - Receives token from API by sending non-permanent code
    //MARK: - Token is saved in UserDefaults
    private func getToken(
        withCode code: String,
        target: GalleryTokenRequestTarget,
        generation: Int,
        failCallback: ((Error?) -> Void)?
    ) {
        Self.tokenAPIClient.exchangeCode(baseURL: target.baseURL, owner: owner, code: code) { [weak self] response in
            guard let self = self,
                  self.isCurrentAuthorization(identity: target.identity, generation: generation) else {
                return
            }
            switch response {
            case .response(let statusCode, let value, _):
                DDLogDebug(
                    "CLOUD_AVAILABILITY authorizationTokenResponse=true statusCode=\(statusCode ?? -1)"
                )
                guard let statusCode = statusCode, statusCode >= 200 && statusCode < 300,
                      let data = value as? NSDictionary,
                      let token = data["token"] as? String,
                      token.isNotEmpty else {
                    failCallback?(nil)
                    self.failAuthorization(target: target, generation: generation)
                    return
                }
                Self.authorizationSuccessWillCommitTestingHandler?()
                guard self.commitAuthorizationSuccess(
                    token: token,
                    target: target,
                    generation: generation
                ) else {
                    DDLogDebug("CLOUD_AVAILABILITY ignoredStaleAuthorizationSuccess=true")
                    return
                }
                self.postGalleryTokenDidChange(target: target)
                if AccountGalleryConfiguration(owner: self.owner).currentGalleryIdentity == target.identity {
                    self.refreshQuota(reason: .tokenReceived, force: true)
                }
                DDLogDebug("CLOUD_AVAILABILITY authorizationCompleted=true")
            case .failure(let statusCode, let error, _):
                let errorCode = (error as NSError?)?.code ?? 0
                DDLogDebug(
                    "CLOUD_AVAILABILITY authorizationTokenFailure=true statusCode=\(statusCode ?? -1) errorCode=\(errorCode)"
                )
                failCallback?(error)
                self.failAuthorization(target: target, generation: generation)
            }
        }
    }

    private func commitAuthorizationSuccess(
        token: String,
        target: GalleryTokenRequestTarget,
        generation: Int
    ) -> Bool {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }

        guard authorizationInFlightIdentity == target.identity,
              authorizationInFlightGeneration == generation,
              tokenExchangeInFlightIdentity == target.identity else {
            return false
        }
        let configuration = AccountGalleryConfiguration(owner: owner)
        let knownEndpoint = configuration.currentGalleryType == target.galleryType
            ? configuration.currentGalleryURL
            : (target.galleryType == .basic
                ? configuration.basicGalleryURL
                : configuration.premiumGalleryURL)
        guard knownEndpoint == target.baseURL else {
            return false
        }

        configuration.storeToken(
            token,
            galleryType: target.galleryType,
            baseURL: target.baseURL
        )
        clearAuthorizationAttemptLocked()
        if configuration.currentGalleryIdentity == target.identity {
            publishAvailability(.ready(endpoint: target.baseURL))
        }
        return true
    }

    private func beginAuthorization(
        target: GalleryTokenRequestTarget,
        selectedIdentity: String
    ) -> Int? {
        authorizationLock.lock()
        if target.identity != selectedIdentity,
           authorizationInFlightIdentity == selectedIdentity {
            authorizationLock.unlock()
            return nil
        }
        if authorizationInFlightIdentity == target.identity {
            authorizationLock.unlock()
            return nil
        }
        authorizationTimeoutWorkItem?.cancel()
        authorizationGeneration += 1
        let generation = authorizationGeneration
        authorizationInFlightIdentity = target.identity
        authorizationInFlightGeneration = generation
        tokenExchangeInFlightIdentity = nil
        let workItem = DispatchWorkItem { [weak self] in
            self?.authorizationDidTimeout(target: target, generation: generation)
        }
        authorizationTimeoutWorkItem = workItem
        authorizationLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.authorizationTimeoutInterval,
            execute: workItem
        )
        return generation
    }

    private func beginTokenExchange(target: GalleryTokenRequestTarget) -> Int? {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        if authorizationInFlightIdentity == target.identity,
           let generation = authorizationInFlightGeneration {
            guard tokenExchangeInFlightIdentity != target.identity else {
                return nil
            }
            tokenExchangeInFlightIdentity = target.identity
            return generation
        }

        // A ready manager may receive a token rotation confirmation that was
        // requested immediately before this manager instance was recreated.
        // Retryable/authorizing managers require a live request generation so
        // a late confirmation cannot revive a timed-out attempt.
        guard case .ready = availabilityRelay.value else {
            return nil
        }
        authorizationGeneration += 1
        let generation = authorizationGeneration
        authorizationInFlightIdentity = target.identity
        authorizationInFlightGeneration = generation
        tokenExchangeInFlightIdentity = target.identity
        authorizationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.authorizationDidTimeout(target: target, generation: generation)
        }
        authorizationTimeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.authorizationTimeoutInterval,
            execute: workItem
        )
        return generation
    }

    private func isCurrentAuthorization(identity: String, generation: Int) -> Bool {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        return authorizationInFlightIdentity == identity
            && authorizationInFlightGeneration == generation
    }

    private func finishPendingAuthorizationIfTokenResolved(identity: String) {
        authorizationLock.lock()
        guard authorizationInFlightIdentity == identity,
              tokenExchangeInFlightIdentity != identity else {
            authorizationLock.unlock()
            return
        }
        clearAuthorizationAttemptLocked()
        authorizationLock.unlock()
    }

    private func failAuthorization(target: GalleryTokenRequestTarget, generation: Int) {
        authorizationLock.lock()
        defer { authorizationLock.unlock() }
        guard authorizationInFlightIdentity == target.identity,
              authorizationInFlightGeneration == generation else {
            return
        }
        clearAuthorizationAttemptLocked()
        guard AccountGalleryConfiguration(owner: owner).currentGalleryIdentity == target.identity else {
            return
        }
        publishAvailability(.retryableFailure(stage: .authorization, endpoint: target.baseURL))
    }

    private func authorizationDidTimeout(target: GalleryTokenRequestTarget, generation: Int) {
        DDLogDebug("CLOUD_AVAILABILITY authorizationTimeout=true endpointKnown=true")
        failAuthorization(target: target, generation: generation)
    }

    private func cancelAuthorization() {
        authorizationLock.lock()
        authorizationGeneration += 1
        clearAuthorizationAttemptLocked()
        authorizationLock.unlock()
    }

    private func clearAuthorizationAttemptLocked() {
        authorizationTimeoutWorkItem?.cancel()
        authorizationTimeoutWorkItem = nil
        authorizationInFlightIdentity = nil
        authorizationInFlightGeneration = nil
        tokenExchangeInFlightIdentity = nil
    }

    private func postGalleryTokenDidChange(target: GalleryTokenRequestTarget) {
        NotificationCenter.default.post(
            name: .cloudStorageGalleryTokenDidChange,
            object: self,
            userInfo: [
                "jid": self.owner,
                "galleryType": target.galleryType.rawValue,
                "galleryURL": target.baseURL.absoluteString,
                "galleryIdentity": target.identity
            ]
        )
    }


    //MARK: - Removes token from UserDefaults
    static func removeToken(for owner: String) {
        AccountGalleryConfiguration(owner: owner).clearKnownTokens()
    }
}
