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
        case .basic: return "Basic"
        case .premium: return "Premium"
        }
    }

    var displayTitle: String {
        switch self {
        case .basic: return "Basic Gallery"
        case .premium: return "Premium Gallery"
        }
    }
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
    static let hardcodedPremiumGalleryURL = "https://gallery.dev.xabber.com/api/v1"

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

    var basicGalleryURL: URL? {
        return Self.normalizedBaseURL(from: storedString(for: Keys.basicGalleryURL))
    }

    var premiumGalleryURL: URL? {
        guard isPremiumGalleryAvailable else {
            return nil
        }
        return Self.normalizedBaseURL(from: storedString(for: Keys.premiumGalleryURL))
            ?? Self.normalizedBaseURL(from: Self.hardcodedPremiumGalleryURL)
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
        return (Self.normalizedBaseURL(from: storedString(for: Keys.premiumGalleryURL))
            ?? Self.normalizedBaseURL(from: Self.hardcodedPremiumGalleryURL)) != nil
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
                ?? Self.normalizedBaseURLString(from: Self.hardcodedPremiumGalleryURL)
            if let normalized = normalized {
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumGalleryURL, value: normalized)
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable, value: true)
                savePremiumMetadata(metadata)
                if !hasManualGallerySelection {
                    saveSelectedGalleryType(.premium, manual: false)
                }
            } else {
                SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: Keys.premiumAvailable, value: false)
                clearPremiumMetadata()
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
        guard let storedType = storedString(for: Keys.quotaGalleryType) else {
            return currentGalleryType == .basic
        }
        guard storedType == currentGalleryType.rawValue else {
            return false
        }
        guard let storedURL = storedString(for: Keys.quotaGalleryURL) else {
            return true
        }
        return storedURL == currentGalleryURL?.absoluteString
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
            ?? Self.normalizedBaseURL(from: Self.hardcodedPremiumGalleryURL)
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
        if normalizedURL == basicGalleryURL?.absoluteString {
            return .basic
        }
        if normalizedURL == premiumGalleryURL?.absoluteString {
            return .premium
        }
        if normalizedURL == currentGalleryURL?.absoluteString {
            return currentGalleryType
        }
        return nil
    }

    func clearPersistedState() {
        clearKnownTokens()

        [
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

struct CloudStorageAccountQuotaPayload: Equatable {
    let used: Int
    let quota: Int

    static func parse(_ value: Any?) -> CloudStorageAccountQuotaPayload? {
        guard let root = dictionary(from: value),
              let used = int(from: root["used"]),
              let quota = int(from: root["quota"]) else {
            return nil
        }
        return CloudStorageAccountQuotaPayload(used: used, quota: quota)
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

enum CloudStorageQuotaAPIResponse {
    case response(statusCode: Int?, value: Any?)
    case failure(statusCode: Int?, error: Error?)
}

protocol CloudStorageQuotaAPIClient {
    func getQuota(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, mimeType: String, metadata: [String: String]?, context: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void)
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
    func getQuota(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/account/quota/") else {
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

    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/slot/") else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        AF.request(
            url,
            method: .get,
            parameters: [
                "size": request.size,
                "name": request.name,
                "hash": request.hash
            ],
            encoding: URLEncoding.default,
            headers: Self.authHeaders(token)
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    func uploadFile(baseURL: URL, token: String, data: Data, filename: String, mimeType: String, metadata: [String: String]?, context: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/upload/"),
              let mimeData = mimeType.data(using: .utf8),
              let contextData = context.data(using: .utf8) else {
            completion(.failure(statusCode: nil, error: nil))
            return
        }

        let metadataData = metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        AF.upload(
            multipartFormData: { formData in
                formData.append(data, withName: "file", fileName: filename, mimeType: mimeType)
                formData.append(mimeData, withName: "media_type")
                formData.append(contextData, withName: "context")
                if let metadataData = metadataData {
                    formData.append(metadataData, withName: "metadata")
                }
            },
            to: url,
            method: .post,
            headers: Self.authHeaders(token)
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
        ).responseJSON { Self.complete($0, completion: completion) }
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
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    func getFilesToDelete(baseURL: URL, token: String, percent: Int, page: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        guard let url = Self.apiURL(baseURL: baseURL, path: "v1/files/percent/\(percent)/"),
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
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    func deleteMediaFor(baseURL: URL, token: String, percent: Int, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        requestDelete(baseURL: baseURL, token: token, path: "v1/files/percent/\(percent)/", parameters: [:], completion: completion)
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

    private static func authHeaders(_ token: String) -> HTTPHeaders {
        return HTTPHeaders(["Authorization": "Bearer \(token)"])
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
        ).responseJSON { Self.complete($0, completion: completion) }
    }

    static func complete(_ response: AFDataResponse<Any>, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        switch response.result {
        case .success(let value):
            completion(.response(statusCode: response.response?.statusCode, value: value))
        case .failure(let error):
            completion(.failure(statusCode: response.response?.statusCode, error: error))
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
        refreshOwnerHandler(owner, reason, force, completion)
    }

    @objc private func premiumEntitlementDidChange(_ notification: Notification) {
        guard let owner = notification.userInfo?["jid"] as? String else { return }
        refresh(owner: owner, reason: .premiumEntitlementChanged, force: true)
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard let owner = notification.userInfo?["jid"] as? String else { return }
        refresh(owner: owner, reason: .galleryEndpointChanged, force: true)
    }

    func resetTestingHooks() {
        ownersProvider = { AccountManager.shared.users.map { $0.jid } }
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

    internal var node: String? = nil

    internal var namespace: String = ""
    internal var maxFileSize: Int? = nil
    private let quotaRefreshLock = NSLock()
    private var isQuotaRefreshInFlight = false
    private var quotaRefreshInFlightContextIdentity: String?
    private var quotaRefreshGeneration = 0
    private var quotaRefreshCallbacks: [(CloudStorageQuotaRefreshResult) -> Void] = []

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
        super.init(withOwner: owner)
    }

    open func isAvailable() -> Bool {
        guard let node = AccountGalleryConfiguration(owner: owner).currentGalleryURL?.absoluteString else {
            return false
        }
        self.node = node
        self.maxFileSize = Int(SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size") ?? "")
        return node.isNotEmpty
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

    private func uploadMimeType(_ mimeType: String, context: String) -> String {
        guard context == "voice",
              mimeType.hasPrefix("audio/"),
              !mimeType.contains("+voice") else {
            return mimeType
        }
        return mimeType + "+voice"
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
            completion(.failure(statusCode: nil, error: UploadError.notAvailable))
            return
        }
        preflightUploadSlot(data: data, filename: filename, context: context, errorCallback: { _ in }) { [weak self] shouldContinue in
            guard let self = self else { return }
            guard shouldContinue, self.isCurrent(context) else {
                completion(.failure(statusCode: 409, error: nil))
                return
            }
            let uploadContext = self.uploadContext(for: mimeType, metadata: metadata)
            let uploadMimeType = self.uploadMimeType(mimeType, context: uploadContext)
            Self.quotaAPIClient.uploadFile(
                baseURL: context.baseURL,
                token: context.token,
                data: data,
                filename: filename,
                mimeType: uploadMimeType,
                metadata: metadata,
                context: uploadContext,
                completion: completion
            )
        }
    }

    //MARK: - Uploads user's file on the server, receives file's and thumbnail's urls
    //MARK: - It is called in Account if the user doesn't have any token yet
    private func uploadFile(message primary: String, data: Data, filename: String, mimeType: String? = nil, metadata: [String: String]? = nil, successCallback: @escaping ((String, String?, Int, String, String, URL, Int, Int) -> Void), failCallback: @escaping ((Error?) -> Void), errorCallback: @escaping ((Int?) -> Void)) {
        guard let context = currentGalleryRequestContext() else {
            failCallback(UploadError.notAvailable)
            return
        }

        guard let uploadURL = AccountGalleryConfiguration.apiURL(baseURL: context.baseURL, path: "v1/files/upload/") else {
            DDLogDebug("XabberUploadManager: \(#function). Url is incorrect")
            errorCallback(nil)
            return
        }

        preflightUploadSlot(data: data, filename: filename, context: context, errorCallback: errorCallback) { [weak self] shouldContinue in
            guard let self = self, shouldContinue else { return }
            guard self.isCurrent(context) else {
                errorCallback(409)
                return
            }

            let uploadContext = self.uploadContext(for: mimeType, metadata: metadata)
            let uploadMimeType = self.uploadMimeType(mimeType ?? "", context: uploadContext)

            Self.quotaAPIClient.uploadFile(
                baseURL: context.baseURL,
                token: context.token,
                data: data,
                filename: filename,
                mimeType: uploadMimeType,
                metadata: metadata,
                context: uploadContext
            ) { [weak self] response in
                guard let self = self else { return }
                guard self.isCurrent(context) else {
                    errorCallback(409)
                    return
                }

                switch response {
                case .response(let code, let value):
                    guard let code = code else {
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
                            errorCallback(statusCode)
                            return
                        }

                        let thumbnailUrl = (json["thumbnail"] as? NSDictionary)?["url"] as? String
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
                        errorCallback(statusCode)
                    }
                case .failure(let code, let error):
                    DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
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
                successCallback()
                return
            }

            references.forEach { reference in
                guard !didFail else { return }
                do {
                    var metadata: [String: String]? = nil
                    let referencePrimary = reference.primary
                    guard let filename = reference.filename, filename.isNotEmpty else {
                        failOnce("Selected file could not be prepared. Please choose it again.".localizeString(id: "upload_error_prepare_failed", arguments: []), code: 400)
                        return
                    }
                    guard let mediaType = reference.metadata?["media-type"] as? String, mediaType.isNotEmpty else {
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
                            failOnce("Selected file could not be encrypted. Please try again.".localizeString(id: "upload_error_encryption_failed", arguments: []), code: 400)
                            return
                        }
                        let encryptionKey = Array<UInt8>(base64: encryptionKeyb64)
                        let iv = Array<UInt8>(base64: ivb64)
                        guard let encrypted = try data.encrypt(key: encryptionKey, iv: iv) else {
                            failOnce("Selected file could not be encrypted. Please try again.".localizeString(id: "upload_error_encryption_failed", arguments: []), code: 400)
                            return
                        }

                        data = encrypted
                        encryptedFiles = true
                    }

                    uploadFile(
                        message: primary,
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
                            DDLogDebug("XabberUploadManager: \(#function). \(String(describing: failError?.localizedDescription))")
                            failOnce("File upload failed. Please try again.".localizeString(id: "upload_error_failed", arguments: []), code: 500)
                        },
                        errorCallback: { errorCode in
                            guard !didFail else { return }
                            didFail = true
                            self.writeErrorInRealm(messageId: primary, errorCode: errorCode)
                            failCallback()
                        })
                } catch {
                    DDLogDebug("XabberUploadManager: \(#function). \(error.localizedDescription)")
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
            enable()
            completion?(.unavailable)
            postQuotaRefreshDidFinish(reason: reason, result: .unavailable)
            return
        }

        guard let generation = beginQuotaRefresh(context: context, completion: completion) else {
            return
        }

        postQuotaRefreshDidStart(reason: reason, context: context)
        Self.quotaAPIClient.getQuota(baseURL: context.baseURL, token: context.token) { [weak self] response in
            guard let self = self else { return }
            guard self.isCurrentQuotaRefresh(generation: generation, context: context) else { return }

            switch response {
            case .response(let code, let value):
                if code == 401 {
                    self.tokenWasExpired(context)
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .unauthorized)
                } else if let code = code, code >= 200 && code < 300,
                          let quotaPayload = CloudStorageAccountQuotaPayload.parse(value) {
                    self.fetchStatsAndStoreQuota(context: context, generation: generation, reason: reason)
                } else {
                    self.fetchStatsAndStoreQuota(context: context, generation: generation, reason: reason)
//                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .failure)
                }

            case .failure(let code, let error):
                if code == 401 {
                    self.tokenWasExpired(context)
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .unauthorized)
                } else {
                    DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                    self.fetchStatsAndStoreQuota(context: context, generation: generation, reason: reason)
//                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .failure)
                }
            }
        }
    }

    private func fetchStatsAndStoreQuota(
        context: CloudStorageGalleryRequestContext,
        generation: Int,
        reason: CloudStorageQuotaRefreshReason
    ) {
        Self.quotaAPIClient.getStats(baseURL: context.baseURL, token: context.token) { [weak self] response in
            guard let self = self else { return }
            guard self.isCurrentQuotaRefresh(generation: generation, context: context) else { return }

            switch response {
            case .response(let code, let value):
                if code == 401 {
                    self.tokenWasExpired(context)
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .unauthorized)
                } else if let code = code, code >= 200 && code < 300, let value = value, let payload = CloudStorageQuotaStatsPayload.parse(value) {
                    let result: CloudStorageQuotaRefreshResult = self.storeQuota(statsPayload: payload, context: context) ? .success : .failure
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: result)
                } else {
                    self.finishQuotaRefresh(generation: generation, context: context, reason: reason, result: .failure)
                }

            case .failure(let code, let error):
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
        guard isCurrent(context) else {
            return false
        }
        do {
            let realm = try WRealm.safe()
            let primary = AccountQuotaStorageItem.genPrimary(jid: owner)
            let item = realm.object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: primary) ?? AccountQuotaStorageItem()
            let isNew = item.primary.isEmpty
            if isNew {
                item.primary = primary
                item.jid = owner
            }

            try realm.write {
                item.quotaBytes = payload.quota
                item.totalBytes = payload.total.used
                item.totalCount = payload.total.count
                self.apply(payload.images, bytes: \.imagesBytes, count: \.imagesCount, to: item)
                self.apply(payload.videos, bytes: \.videosBytes, count: \.videosCount, to: item)
                self.apply(payload.files, bytes: \.filesBytes, count: \.filesCount, to: item)
                self.apply(payload.audio, bytes: \.audioBytes, count: \.audioCount, to: item)
                self.apply(payload.voices, bytes: \.voicesBytes, count: \.voicesCount, to: item)
                self.apply(payload.avatars, bytes: \.avatarsBytes, count: \.avatarsCount, to: item)
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
        to item: AccountQuotaStorageItem
    ) {
        guard let category = category else { return }
        item[keyPath: bytes] = category.used
        item[keyPath: count] = category.count
    }

    private func beginQuotaRefresh(
        context: CloudStorageGalleryRequestContext,
        completion: ((CloudStorageQuotaRefreshResult) -> Void)?
    ) -> Int? {
        quotaRefreshLock.lock()
        defer { quotaRefreshLock.unlock() }

        if isQuotaRefreshInFlight,
           quotaRefreshInFlightContextIdentity == context.identity {
            if let completion = completion {
                quotaRefreshCallbacks.append(completion)
            }
            return nil
        }

        quotaRefreshGeneration += 1
        isQuotaRefreshInFlight = true
        quotaRefreshInFlightContextIdentity = context.identity
        quotaRefreshCallbacks = completion.map { [$0] } ?? []
        return quotaRefreshGeneration
    }

    private func isCurrentQuotaRefresh(generation: Int, context: CloudStorageGalleryRequestContext) -> Bool {
        quotaRefreshLock.lock()
        let isCurrentGeneration = isQuotaRefreshInFlight
            && quotaRefreshGeneration == generation
            && quotaRefreshInFlightContextIdentity == context.identity
        quotaRefreshLock.unlock()
        return isCurrentGeneration && isCurrent(context)
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
              quotaRefreshInFlightContextIdentity == context.identity else {
            quotaRefreshLock.unlock()
            return
        }
        let callbacks = quotaRefreshCallbacks
        quotaRefreshCallbacks = []
        isQuotaRefreshInFlight = false
        quotaRefreshInFlightContextIdentity = nil
        quotaRefreshLock.unlock()

        postQuotaRefreshDidFinish(reason: reason, result: result, context: context)
        callbacks.forEach { $0(result) }
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
        errorCallback: @escaping ((Int?) -> Void),
        completion: @escaping (Bool) -> Void
    ) {
        guard let context = providedContext ?? currentGalleryRequestContext() else {
            completion(true)
            return
        }

        let request = CloudStorageUploadSlotRequest(
            size: data.count,
            name: filename,
            hash: data.sha256Data.hexEncodedString()
        )

        Self.quotaAPIClient.requestSlot(baseURL: context.baseURL, token: context.token, request: request) { [weak self] response in
            guard let self = self else { return }
            guard self.isCurrent(context) else {
                completion(false)
                return
            }

            let code: Int?
            switch response {
            case .response(let statusCode, _):
                code = statusCode
            case .failure(let statusCode, _):
                code = statusCode
            }

            if code == 403 {
                errorCallback(403)
                self.refreshQuotaIfCurrent(context, reason: .uploadQuotaExceeded, force: true)
                completion(false)
            } else {
                if code == 401 {
                    self.tokenWasExpired(context)
                }
                completion(true)
            }
        }
    }

    //MARK: - Deletes one media file with selected id
    public func deleteMediaFromServer(fileID: Int) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.deleteMedia(baseURL: context.baseURL, token: context.token, fileID: fileID) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, _):
                if let code = code, code >= 200 && code < 300 {
                    self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
                } else if code == 401 {
                    self.tokenWasExpired(context)
                }
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
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
        AccountGalleryConfiguration(owner: owner).clearToken(galleryType: context.galleryType, baseURL: context.baseURL)
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            guard let fullJID = stream.myJID?.full else { return }
            user.cloudStorage.getCode(fullJID: fullJID, target: GalleryTokenRequestTarget(context: context))
        })
    }

    private struct PagePayload {
        let items: [NSDictionary]
        let totalObjects: Int
        let objPerPage: Int
        let totalPages: Int
    }

    private func pagePayload(from json: NSDictionary) -> PagePayload? {
        let items = json["items"] as? [NSDictionary] ?? []
        let totalObjects = int(from: json["total_objects"]) ?? items.count
        let objPerPage = int(from: json["obj_per_page"]) ?? max(items.count, 1)
        let totalPages = int(from: json["total_pages"]) ?? 1
        return PagePayload(
            items: items,
            totalObjects: totalObjects,
            objPerPage: objPerPage,
            totalPages: max(totalPages, 1)
        )
    }

    //MARK: - Deletes avatar with selected id
    public func deleteAvatarFromServer(fileID: Int) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.deleteAvatar(baseURL: context.baseURL, token: context.token, fileID: fileID) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, _):
                if let code = code, code >= 200 && code < 300 {
                    self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
                } else if code == 401 {
                    self.tokenWasExpired(context)
                }
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
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
            case .response(let code, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                }
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
        }
    }

    func getFilesOfType(type: MimeIconTypes, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.getFiles(baseURL: context.baseURL, token: context.token, type: type, page: page) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, let value):
                if code == 401 { self.tokenWasExpired(context); return }
                guard let json = value as? NSDictionary,
                      let page = self.pagePayload(from: json) else { return }
                callback(page.items, page.totalObjects, page.objPerPage, page.totalPages)
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
        }
    }

    func getAvatars(page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.getAvatars(baseURL: context.baseURL, token: context.token, page: page) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, let value):
                if code == 401 { self.tokenWasExpired(context); return }
                guard let json = value as? NSDictionary,
                      let page = self.pagePayload(from: json) else { return }
                callback(page.items, page.totalObjects, page.objPerPage, page.totalPages)
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
        }
    }

    func getFilesToDeleteByPercent(percent: Int, page: Int, callback: @escaping ([NSDictionary], Int, Int, Int) -> Void) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.getFilesToDelete(baseURL: context.baseURL, token: context.token, percent: percent, page: page) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, let value):
                if code == 401 { self.tokenWasExpired(context); return }
                guard let json = value as? NSDictionary,
                      let page = self.pagePayload(from: json),
                      page.totalObjects > 0 else { return }
                callback(page.items, page.totalObjects, page.objPerPage, page.totalPages)
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
        }
    }

    //MARK: - Deletes all media files for selected period
    public func deleteMediaFor(percent: Int, callback: (() -> Void)?) {
        guard let context = currentGalleryRequestContext() else {
            DDLogDebug("XabberUploadManager (\(#function) is unavailable.")
            return
        }

        Self.quotaAPIClient.deleteMediaFor(baseURL: context.baseURL, token: context.token, percent: percent) { [weak self] response in
            guard let self = self, self.isCurrent(context) else { return }
            switch response {
            case .response(let code, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                } else {
                    self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
                }
            case .failure(let code, let error):
                DDLogDebug("XabberUploadManager: \(#function). \(error?.localizedDescription ?? "Unknown error")")
                if code == 401 { self.tokenWasExpired(context) }
            }
            callback?()
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
            case .response(let code, _):
                if code == 401 {
                    self.tokenWasExpired(context)
                } else {
                    self.refreshQuotaIfCurrent(context, reason: .manual, force: true)
                }
            case .failure(let code, let error):
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
        guard AccountGalleryConfiguration(owner: owner).token(for: galleryType, baseURL: baseURL).isEmpty,
              let fulljid = AccountManager.shared.find(for: self.owner)?.xmppStream.myJID?.full else {
            return
        }
        getCode(fullJID: fulljid, target: GalleryTokenRequestTarget(owner: owner, galleryType: galleryType, baseURL: baseURL))
    }

    //MARK: - Sends inquiry to the server in order to get non-permanent code
    private func getCode(fullJID: String, target: GalleryTokenRequestTarget, failCallback: ((String?) -> Void)? = nil) {
        Self.tokenAPIClient.requestCode(baseURL: target.baseURL, fullJID: fullJID) { response in
            switch response {
            case .response(let code, let value):
                if let code = code, code >= 200 && code < 300 {
                    DDLogDebug(value ?? [:])
                } else {
                    failCallback?(nil)
                }
            case .failure(_, let error):
                DispatchQueue.main.async {
                    ToastPresenter().presentError(message: "Cloud storage is inactive")
                }
                failCallback?(error?.localizedDescription)
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
        getToken(withCode: code, target: target, failCallback: nil)
        return true
    }


    //MARK: - Receives token from API by sending non-permanent code
    //MARK: - Token is saved in UserDefaults
    private func getToken(withCode code: String, target: GalleryTokenRequestTarget, failCallback: ((Error?) -> Void)?) {
        Self.tokenAPIClient.exchangeCode(baseURL: target.baseURL, owner: owner, code: code) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .response(let statusCode, let value):
                guard let statusCode = statusCode, statusCode >= 200 && statusCode < 300,
                      let data = value as? NSDictionary,
                      let token = data["token"] as? String,
                      token.isNotEmpty else {
                    failCallback?(nil)
                    return
                }
                AccountGalleryConfiguration(owner: self.owner).storeToken(token, galleryType: target.galleryType, baseURL: target.baseURL)
                self.postGalleryTokenDidChange(target: target)
                if AccountGalleryConfiguration(owner: self.owner).currentGalleryIdentity == target.identity {
                    self.refreshQuota(reason: .tokenReceived, force: true)
                }
                DDLogDebug("Received media gallery token for \(target.identity)")
            case .failure(_, let error):
                failCallback?(error)
            }
        }
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
