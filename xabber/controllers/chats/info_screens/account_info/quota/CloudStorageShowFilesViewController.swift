//
//  CloudStorageShowFilesViewController.swift
//  xabber
//
//  Created by MacIntel on 27.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RxSwift
import CocoaLumberjack

enum CloudStorageCleanupPolicy {
    static let supportedPercents = [25, 50, 75]

    static func freePercentage(quotaBytes: Int, usedBytes: Int) -> Int {
        guard quotaBytes > 0 else { return 0 }
        let boundedUsed = min(quotaBytes, max(0, usedBytes))
        let freeBytes = quotaBytes - boundedUsed
        var value = Decimal(freeBytes) * Decimal(100) / Decimal(quotaBytes)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .down)
        let percent = NSDecimalNumber(decimal: rounded).intValue
        return min(100, max(0, percent))
    }

    static func isEnabled(percent: Int, currentFreePercent: Int) -> Bool {
        return supportedPercents.contains(percent) && currentFreePercent < percent
    }

    static func hasEnabledTarget(currentFreePercent: Int) -> Bool {
        return supportedPercents.contains {
            isEnabled(percent: $0, currentFreePercent: currentFreePercent)
        }
    }
}

enum CloudStorageCategoryLayoutPolicy {
    static let numberOfColumns = InfoScreenFooterView.numberOfCells
    static let spacing = InfoScreenFooterView.cellSpacing
    static let sectionInsets = UIEdgeInsets(
        top: 12,
        left: InfoScreenFooterView.cellSpacing,
        bottom: 15,
        right: InfoScreenFooterView.cellSpacing
    )
    static let listItemHeight: CGFloat = 60

    static func gridItemWidth(containerWidth: CGFloat) -> CGFloat {
        let width = containerWidth / numberOfColumns
            - spacing * (numberOfColumns + 1) / numberOfColumns
        return floor(width * 100) / 100
    }

    static func listItemWidth(containerWidth: CGFloat) -> CGFloat {
        return max(0, containerWidth - sectionInsets.left - sectionInsets.right)
    }
}

struct CloudStorageQuotaCategoryRow: Equatable {
    let count: Int
    let bytes: Int

    var detailText: String {
        return "\(max(0, count)) \u{00b7} \(AccountQuotaStorageItem.beautify(size: max(0, bytes)))"
    }
}

enum CloudStorageQuotaCategoryPresentation {
    static func rows(from item: AccountQuotaStorageItem) -> [String: CloudStorageQuotaCategoryRow] {
        return [
            "images": CloudStorageQuotaCategoryRow(count: item.imagesCount, bytes: item.imagesBytes),
            "videos": CloudStorageQuotaCategoryRow(count: item.videosCount, bytes: item.videosBytes),
            "files": CloudStorageQuotaCategoryRow(count: item.filesCount, bytes: item.filesBytes),
            "audio": CloudStorageQuotaCategoryRow(count: item.voicesCount, bytes: item.voicesBytes),
            "avatars": CloudStorageQuotaCategoryRow(count: item.avatarsCount, bytes: item.avatarsBytes)
        ]
    }
}

struct CloudStorageListPage {
    let items: [NSDictionary]
    let totalObjects: Int
    let objectsPerPage: Int
    let totalPages: Int
    let page: Int
}

enum CloudStorageListLoadError: Error, Equatable {
    case unavailable
    case unauthorized
    case staleSelection
    case invalidResponse
    case server(statusCode: Int)
    case transport
}

final class CloudStoragePagedLoader {
    typealias FetchPage = (Int, @escaping (Result<CloudStorageListPage, CloudStorageListLoadError>) -> Void) -> Void

    func loadAll(
        fetchPage: @escaping FetchPage,
        completion: @escaping (Result<[NSDictionary], CloudStorageListLoadError>) -> Void
    ) {
        Session(fetchPage: fetchPage, completion: completion).start()
    }

    private final class Session {
        private let fetchPage: FetchPage
        private let completion: (Result<[NSDictionary], CloudStorageListLoadError>) -> Void
        private let lock = NSLock()
        private var waitingForPage: Int?
        private var totalPages = 1
        private var accumulatedItems: [NSDictionary] = []
        private var seenIdentities: Set<String> = []
        private var isFinished = false

        init(
            fetchPage: @escaping FetchPage,
            completion: @escaping (Result<[NSDictionary], CloudStorageListLoadError>) -> Void
        ) {
            self.fetchPage = fetchPage
            self.completion = completion
        }

        func start() {
            request(page: 1)
        }

        private func request(page: Int) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            waitingForPage = page
            lock.unlock()

            fetchPage(page) { [self] result in
                receive(result, requestedPage: page)
            }
        }

        private func receive(
            _ result: Result<CloudStorageListPage, CloudStorageListLoadError>,
            requestedPage: Int
        ) {
            lock.lock()
            guard !isFinished, waitingForPage == requestedPage else {
                lock.unlock()
                return
            }
            waitingForPage = nil

            switch result {
            case .failure(let error):
                isFinished = true
                lock.unlock()
                completion(.failure(error))

            case .success(let page):
                totalPages = max(totalPages, max(1, page.totalPages))
                appendUnique(page.items)
                if requestedPage >= totalPages {
                    isFinished = true
                    let items = accumulatedItems
                    lock.unlock()
                    completion(.success(items))
                } else {
                    let nextPage = requestedPage + 1
                    lock.unlock()
                    request(page: nextPage)
                }
            }
        }

        private func appendUnique(_ items: [NSDictionary]) {
            items.forEach { item in
                guard let identity = Self.identity(for: item) else {
                    accumulatedItems.append(item)
                    return
                }
                if seenIdentities.insert(identity).inserted {
                    accumulatedItems.append(item)
                }
            }
        }

        private static func identity(for item: NSDictionary) -> String? {
            if let value = item["id"] as? NSNumber {
                return "id:\(value.stringValue)"
            }
            if let value = item["id"] as? String, value.isNotEmpty {
                return "id:\(value)"
            }
            return nil
        }
    }
}

class CloudStorageShowFilesViewController: BaseViewController {
    struct Datasource {
        enum Kind: Equatable {
            case image
            case video
            case file
            case voice
            case avatar
            case undefined
        }
        
        var uri: String? = nil
        var thumbnail: String? = nil
        var kind: Kind
        var videoPreviewKey: String? = nil
        var videoDuration: String? = nil
        var audioDuration: String? = nil
        var meters: String? = nil
        var mimeType: String? = nil
        var fileName: String? = nil
        var voiceModel: AudioAttachment? = nil
        var dateFormatted: Date? = nil
        var date: String? = nil
        var time: String? = nil
        var size: String? = nil
        var senderName: String? = nil
        var messageId: String? = nil
        var fileId: Int? = nil
    }
    
    var totalPages: Int
    var items: [NSDictionary]
    var currentPage: Int = 1
    
    lazy var spinner: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = UIColor.gray
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        return activityIndicator
    }()
    
    init(owner: String) {
        self.items = []
        self.totalPages = 0
        super.init(nibName: nil, bundle: nil)
        self.owner = owner
    }
    
    init(owner: String, items: [NSDictionary], totalPages: Int) {
        self.items = items
        self.totalPages = totalPages
        super.init(nibName: nil, bundle: nil)
        self.owner = owner
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum CloudStorageItemPresentation {
    static func make(
        from payload: NSDictionary,
        preferredType: MimeIconTypes? = nil
    ) -> CloudStorageShowFilesViewController.Datasource? {
        guard let rawURL = string(payload["file"]),
              let encodedURL = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              URL(string: encodedURL) != nil else {
            return nil
        }

        let metadata = dictionary(payload["metadata"])
        let createdAt = string(payload["created_at"]).flatMap(parseDate)
        let dateAndTime = createdAt.map { PhotoGallery.prepareDate(date: $0) }
        let size = max(0, int(payload["size"]) ?? 0)
        let mimeType = normalizedMimeType(string(payload["media_type"]))
        let kind = resolvedKind(
            context: string(payload["context"]),
            mimeType: mimeType,
            preferredType: preferredType
        )

        return CloudStorageShowFilesViewController.Datasource(
            uri: encodedURL,
            kind: kind,
            videoPreviewKey: string(metadata?["video_preview_key"]),
            videoDuration: string(metadata?["duration"]),
            audioDuration: string(metadata?["duration"]),
            meters: string(metadata?["meters"]),
            mimeType: mimeType,
            fileName: string(payload["name"]) ?? "File",
            dateFormatted: createdAt,
            date: dateAndTime?.date ?? "",
            time: dateAndTime?.send_time ?? "",
            size: AccountQuotaStorageItem.beautify(size: size),
            fileId: int(payload["id"])
        )
    }

    static func grouped(
        _ items: [NSDictionary]
    ) -> [[CloudStorageShowFilesViewController.Datasource]] {
        let mapped = items.compactMap { make(from: $0) }
        let order: [CloudStorageShowFilesViewController.Datasource.Kind] = [.image, .video, .file, .voice, .avatar]
        return order.compactMap { kind in
            let values = mapped
                .filter { $0.kind == kind }
                .sorted { ($0.dateFormatted ?? .distantPast) > ($1.dateFormatted ?? .distantPast) }
            return values.isEmpty ? nil : values
        }
    }

    private static func resolvedKind(
        context: String?,
        mimeType: String?,
        preferredType: MimeIconTypes?
    ) -> CloudStorageShowFilesViewController.Datasource.Kind {
        switch context?.lowercased() {
        case "avatar": return .avatar
        case "voice": return .voice
        default: break
        }

        if let preferredType {
            switch preferredType {
            case .image: return .image
            case .video: return .video
            case .audio: return .voice
            case .avatar: return .avatar
            default: return .file
            }
        }

        guard let mimeType else { return .file }
        switch mimeIcon[mimeType] ?? mimeIcon[String(mimeType.split(separator: "/").first ?? "")] ?? .file {
        case .image: return .image
        case .video: return .video
        case .audio: return .voice
        case .avatar: return .avatar
        default: return .file
        }
    }

    private static func normalizedMimeType(_ value: String?) -> String? {
        return value?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = DateFormatter()
        fractional.locale = Locale(identifier: "en_US_POSIX")
        fractional.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = fractional.date(from: value) {
            return date
        }

        let seconds = DateFormatter()
        seconds.locale = Locale(identifier: "en_US_POSIX")
        seconds.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let date = seconds.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dictionary(_ value: Any?) -> NSDictionary? {
        if let value = value as? NSDictionary { return value }
        if let value = value as? [String: Any] { return value as NSDictionary }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, value.isNotEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

protocol TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String)
}

extension CloudStorageShowFilesViewController: TappedPhotoInCloudGallery {
    func tappedPhotoInGallery(primary: String) {
        do {
            let realm = try WRealm.safe()
            let item = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            let chatViewController = ChatViewController()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return
        }
    }
}
