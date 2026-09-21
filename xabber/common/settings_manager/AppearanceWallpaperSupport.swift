//
//  AppearanceWallpaperSupport.swift
//  xabber
//
//  Created by Codex on 04.09.2026.
//

import CryptoKit
import Foundation
import UIKit

struct AppearanceProcessedWallpaperAsset: Equatable {
    let data: Data
    let hash: String
    let filename: String
    let mimeType: String
}

enum AppearanceWallpaperProcessingError: Error, Equatable {
    case invalidImage
    case encodingFailed
}

enum AppearanceWallpaperPhotoProcessor {
    static let maximumLongEdge: CGFloat = 3072
    static let jpegQuality: CGFloat = 0.85

    static func process(
        _ image: UIImage,
        maximumLongEdge: CGFloat = maximumLongEdge,
        jpegQuality: CGFloat = jpegQuality
    ) throws -> AppearanceProcessedWallpaperAsset {
        guard maximumLongEdge > 0 else {
            throw AppearanceWallpaperProcessingError.invalidImage
        }

        let sourceSize: CGSize
        if let cgImage = image.cgImage {
            sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else if image.size.width > 0, image.size.height > 0 {
            sourceSize = image.size
        } else {
            throw AppearanceWallpaperProcessingError.invalidImage
        }

        let scale = min(1, maximumLongEdge / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let data = normalized.jpegData(compressionQuality: jpegQuality) else {
            throw AppearanceWallpaperProcessingError.encodingFailed
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AppearanceProcessedWallpaperAsset(
            data: data,
            hash: hash,
            filename: "chat-wallpaper-\(hash.prefix(12)).jpg",
            mimeType: "image/jpeg"
        )
    }
}

final class AppearanceWallpaperCache {
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        let groupID = CredentialsManager.uniqueAccessGroup()
        let appGroupRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
        let fallback = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.init(
            rootDirectory: (appGroupRoot ?? fallback)
                .appendingPathComponent("AppearanceWallpapers", isDirectory: true),
            fileManager: fileManager
        )
    }

    func fileURL(for reference: CloudWallpaperReference) -> URL {
        let identity = [reference.owner, reference.galleryIdentity, reference.fileID]
            .joined(separator: "|")
        let identityHash = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let hash = reference.hash.isEmpty ? "wallpaper" : reference.hash
        return rootDirectory.appendingPathComponent("\(hash)-\(identityHash.prefix(12)).jpg")
    }

    func store(_ data: Data, for reference: CloudWallpaperReference) throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: fileURL(for: reference), options: .atomic)
    }

    func data(for reference: CloudWallpaperReference) -> Data? {
        try? Data(contentsOf: fileURL(for: reference), options: [.mappedIfSafe])
    }

    func image(for reference: CloudWallpaperReference) -> UIImage? {
        data(for: reference).flatMap(UIImage.init(data:))
    }
}

enum AppearanceCloudWallpaperError: LocalizedError {
    case accountUnavailable
    case galleryUnavailable
    case staleGallery
    case unauthorized
    case quotaExceeded
    case invalidResponse
    case transport(Error?)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: return L10n.text("appearance_wallpaper__localized_error_description__no_enabled_account_is_available_for_cloud_storage", fallback: "No enabled account is available for Cloud Storage.")
        case .galleryUnavailable: return L10n.text("appearance_wallpaper__localized_error_description__cloud_storage_is_not_ready_yet", fallback: "Cloud Storage is not ready yet.")
        case .staleGallery: return L10n.text("appearance_wallpaper__localized_error_description__the_cloud_storage_gallery_changed_during_upload", fallback: "The Cloud Storage gallery changed during upload.")
        case .unauthorized: return L10n.text("appearance_wallpaper__localized_error_description__cloud_storage_authorization_expired", fallback: "Cloud Storage authorization expired.")
        case .quotaExceeded: return L10n.text("appearance_wallpaper__localized_error_description__there_is_not_enough_cloud_storage_space", fallback: "There is not enough Cloud Storage space.")
        case .invalidResponse: return L10n.text("appearance_wallpaper__localized_error_description__cloud_storage_returned_an_invalid_response", fallback: "Cloud Storage returned an invalid response.")
        case .transport(let error): return error?.localizedDescription ?? L10n.text("appearance_wallpaper__localized_error_description__could_not_upload_wallpaper", fallback: "Could not upload the wallpaper.")
        }
    }
}

extension AppearanceCloudOwnerCandidate {
    /// `AccountManager.users` contains only accounts that are currently enabled.
    /// Do not consult `activeUsers` here: it is an asynchronously populated
    /// connection relay and can legitimately be empty while Settings is ready.
    static func fromLoadedEnabledAccount(
        owner: String,
        isPremium: Bool,
        requestContext: CloudStorageGalleryRequestContext?
    ) -> AppearanceCloudOwnerCandidate {
        fromUploadRequestContext(
            owner: owner,
            isEnabled: true,
            isPremium: isPremium,
            requestContext: requestContext
        )
    }

    /// A resolved request context carries the currently selected Gallery URL and
    /// its scoped token. It is the source of truth for whether a photo upload
    /// can start; the availability relay is only presentation state and can
    /// lag a valid context during a reconnect or quota refresh.
    static func fromUploadRequestContext(
        owner: String,
        isEnabled: Bool,
        isPremium: Bool,
        requestContext: CloudStorageGalleryRequestContext?
    ) -> AppearanceCloudOwnerCandidate {
        AppearanceCloudOwnerCandidate(
            owner: owner,
            galleryIdentity: requestContext?.identity ?? "",
            isEnabled: isEnabled,
            isPremium: isPremium,
            isReady: requestContext != nil
        )
    }
}

final class XabberAppearanceCloudWallpaperClient: AppearanceCloudWallpaperClient {
    private let cache: AppearanceWallpaperCache

    init(cache: AppearanceWallpaperCache = AppearanceWallpaperCache()) {
        self.cache = cache
    }

    func upload(
        request: AppearanceCloudWallpaperUploadRequest,
        completion: @escaping (Result<CloudWallpaperReference, Error>) -> Void
    ) {
        guard let account = AccountManager.shared.find(for: request.owner) else {
            completion(.failure(AppearanceCloudWallpaperError.accountUnavailable))
            return
        }
        guard AccountGalleryConfiguration(owner: request.owner).currentGalleryIdentity == request.galleryIdentity else {
            completion(.failure(AppearanceCloudWallpaperError.staleGallery))
            return
        }
        account.cloudStorage.uploadMedia(
            data: request.data,
            filename: request.filename,
            mimeType: request.mimeType,
            metadata: request.metadata
        ) { [cache] response in
            DispatchQueue.main.async {
                guard AccountGalleryConfiguration(owner: request.owner).currentGalleryIdentity == request.galleryIdentity else {
                    completion(.failure(AppearanceCloudWallpaperError.staleGallery))
                    return
                }
                switch response {
                case .response(let code, let value, _):
                    guard let code else {
                        completion(.failure(AppearanceCloudWallpaperError.invalidResponse))
                        return
                    }
                    if code == 401 {
                        completion(.failure(AppearanceCloudWallpaperError.unauthorized))
                        return
                    }
                    if code == 403 {
                        completion(.failure(AppearanceCloudWallpaperError.quotaExceeded))
                        return
                    }
                    guard (200..<300).contains(code),
                          let json = value as? NSDictionary,
                          let url = json["file"] as? String,
                          let fileID = Self.string(from: json["id"]),
                          let hash = json["hash"] as? String else {
                        completion(.failure(AppearanceCloudWallpaperError.invalidResponse))
                        return
                    }
                    let thumbnailURL = (json["thumbnail"] as? NSDictionary)?["url"] as? String
                    let reference = CloudWallpaperReference(
                        owner: request.owner,
                        galleryIdentity: request.galleryIdentity,
                        fileID: fileID,
                        url: url,
                        thumbnailURL: thumbnailURL,
                        hash: hash,
                        mimeType: request.mimeType
                    )
                    do {
                        try cache.store(request.data, for: reference)
                        completion(.success(reference))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let code, let error, _):
                    switch code {
                    case 401: completion(.failure(AppearanceCloudWallpaperError.unauthorized))
                    case 403: completion(.failure(AppearanceCloudWallpaperError.quotaExceeded))
                    case 409: completion(.failure(AppearanceCloudWallpaperError.staleGallery))
                    default: completion(.failure(AppearanceCloudWallpaperError.transport(error)))
                    }
                }
            }
        }
    }

    private static func string(from value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let int = value as? Int { return String(int) }
        return nil
    }
}

struct LiveAppearanceEntitlementProvider: AppearanceEntitlementProviding {
    var hasActiveAppearanceEntitlement: Bool {
        SubscribtionsManager.shared.hasActiveSubsription()
    }

    var areSubscriptionsEnabled: Bool {
        CommonConfigManager.shared.config.support_subscribtions
    }
}
