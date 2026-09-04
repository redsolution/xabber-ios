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

    var sizeText: String {
        return AccountQuotaStorageItem.beautify(size: max(0, bytes))
    }
}

enum CloudStorageQuotaCategoryPresentation {
    static func rows(from item: AccountQuotaStorageItem) -> [String: CloudStorageQuotaCategoryRow] {
        return [
            "images": CloudStorageQuotaCategoryRow(count: item.imagesCount, bytes: item.imagesBytes),
            "videos": CloudStorageQuotaCategoryRow(count: item.videosCount, bytes: item.videosBytes),
            "voice": CloudStorageQuotaCategoryRow(count: item.voicesCount, bytes: item.voicesBytes),
            "calls": CloudStorageQuotaCategoryRow(count: item.audioCount, bytes: item.audioBytes),
            "files": CloudStorageQuotaCategoryRow(count: item.filesCount, bytes: item.filesBytes),
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

struct CloudStorageGalleryCacheKey: Hashable {
    let owner: String
    let galleryIdentity: String
    let categoryRawValue: String

    init(owner: String, galleryIdentity: String, category: CloudStorageOverviewCategory) {
        self.owner = owner
        self.galleryIdentity = galleryIdentity
        self.categoryRawValue = category.rawValue
    }
}

struct CloudStorageGalleryCacheSnapshot {
    let items: [NSDictionary]
    let currentPage: Int
    let totalPages: Int
}

final class CloudStorageGalleryMemoryCache {
    static let shared = CloudStorageGalleryMemoryCache(
        maximumAge: 5 * 60,
        notificationCenter: .default
    )

    private struct Entry {
        let snapshot: CloudStorageGalleryCacheSnapshot
        let storedAt: Date
    }

    private let maximumAge: TimeInterval
    private let now: () -> Date
    private let notificationCenter: NotificationCenter?
    private let lock = NSLock()
    private var entries: [CloudStorageGalleryCacheKey: Entry] = [:]
    private var observers: [NSObjectProtocol] = []

    init(
        maximumAge: TimeInterval,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter? = nil
    ) {
        self.maximumAge = max(0, maximumAge)
        self.now = now
        self.notificationCenter = notificationCenter

        if let notificationCenter {
            observers.append(notificationCenter.addObserver(
                forName: .cloudStorageContentDidChange,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let owner = notification.userInfo?["jid"] as? String else { return }
                self?.invalidate(
                    owner: owner,
                    galleryIdentity: notification.userInfo?["galleryIdentity"] as? String
                )
            })
            observers.append(notificationCenter.addObserver(
                forName: .cloudStorageGalleryDidChange,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let owner = notification.userInfo?["jid"] as? String else { return }
                self?.invalidate(owner: owner, galleryIdentity: nil)
            })
        }
    }

    deinit {
        observers.forEach { notificationCenter?.removeObserver($0) }
    }

    func snapshot(for key: CloudStorageGalleryCacheKey) -> CloudStorageGalleryCacheSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) <= maximumAge else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    func store(_ snapshot: CloudStorageGalleryCacheSnapshot, for key: CloudStorageGalleryCacheKey) {
        lock.lock()
        entries[key] = Entry(snapshot: snapshot, storedAt: now())
        lock.unlock()
    }

    func invalidate(owner: String, galleryIdentity: String?) {
        lock.lock()
        entries.keys
            .filter { key in
                key.owner == owner
                    && (galleryIdentity == nil || key.galleryIdentity == galleryIdentity)
            }
            .forEach { entries.removeValue(forKey: $0) }
        lock.unlock()
    }
}

enum CloudStorageGalleryPagingIndicator: Equatable {
    case none
    case initialLoading
    case initialRetry
    case nextPageLoading
    case nextPageRetry
    case refreshRetry
}

final class CloudStorageIncrementalPager {
    struct State {
        fileprivate(set) var items: [NSDictionary] = []
        fileprivate(set) var currentPage = 0
        fileprivate(set) var totalPages = 1
        fileprivate(set) var loadingPage: Int?
        fileprivate(set) var failedPage: Int?
        fileprivate(set) var error: CloudStorageListLoadError?
        fileprivate(set) var isShowingCachedContent = false

        var isLoading: Bool {
            return loadingPage != nil
        }

        var canLoadNextPage: Bool {
            return !isLoading
                && failedPage == nil
                && currentPage > 0
                && currentPage < totalPages
        }

        var indicator: CloudStorageGalleryPagingIndicator {
            if loadingPage == 1, items.isEmpty {
                return .initialLoading
            }
            if failedPage == 1, items.isEmpty {
                return .initialRetry
            }
            if let loadingPage, loadingPage > 1 {
                return .nextPageLoading
            }
            if let failedPage, !items.isEmpty {
                return failedPage == 1 ? .refreshRetry : .nextPageRetry
            }
            return .none
        }
    }

    typealias FetchPage = (
        Int,
        @escaping (Result<CloudStorageListPage, CloudStorageListLoadError>) -> Void
    ) -> CloudStorageRequestCancelling?

    private let cacheKey: CloudStorageGalleryCacheKey
    private let cache: CloudStorageGalleryMemoryCache
    private let fetchPage: FetchPage
    private var requestGeneration = 0
    private var activeRequest: CloudStorageRequestCancelling?
    private var waitingForPage: Int?

    var onStateChange: ((State) -> Void)?
    private(set) var state = State()

    init(
        cacheKey: CloudStorageGalleryCacheKey,
        cache: CloudStorageGalleryMemoryCache = .shared,
        fetchPage: @escaping FetchPage
    ) {
        self.cacheKey = cacheKey
        self.cache = cache
        self.fetchPage = fetchPage
    }

    deinit {
        activeRequest?.cancel()
    }

    func start() {
        activeRequest?.cancel()
        activeRequest = nil
        requestGeneration += 1
        waitingForPage = nil

        if let cached = cache.snapshot(for: cacheKey) {
            state.items = cached.items
            state.currentPage = max(0, cached.currentPage)
            state.totalPages = max(1, cached.totalPages)
            state.isShowingCachedContent = cached.items.isNotEmpty
        } else {
            state = State()
        }
        state.failedPage = nil
        state.error = nil
        publish()
        request(page: 1)
    }

    func loadNextPageIfNeeded() {
        guard state.canLoadNextPage else { return }
        request(page: state.currentPage + 1)
    }

    func retryFailedPage() {
        guard let failedPage = state.failedPage, !state.isLoading else { return }
        request(page: failedPage)
    }

    func cancel() {
        requestGeneration += 1
        activeRequest?.cancel()
        activeRequest = nil
        waitingForPage = nil
        state.loadingPage = nil
        publish()
    }

    func removeItems(fileIDs: Set<Int>) {
        guard fileIDs.isNotEmpty else { return }
        state.items.removeAll { payload in
            guard let fileID = Self.fileID(from: payload["id"]) else { return false }
            return fileIDs.contains(fileID)
        }
        storeSnapshot()
        publish()
    }

    private func request(page: Int) {
        guard page > 0, waitingForPage == nil else { return }
        state.failedPage = nil
        state.error = nil
        state.loadingPage = page
        waitingForPage = page
        publish()

        let generation = requestGeneration
        let cancellation = fetchPage(page) { [weak self] result in
            self?.receive(result, requestedPage: page, generation: generation)
        }
        if requestGeneration == generation, waitingForPage == page {
            activeRequest = cancellation
        } else {
            cancellation?.cancel()
        }
    }

    private func receive(
        _ result: Result<CloudStorageListPage, CloudStorageListLoadError>,
        requestedPage: Int,
        generation: Int
    ) {
        guard generation == requestGeneration, waitingForPage == requestedPage else { return }
        waitingForPage = nil
        activeRequest = nil
        state.loadingPage = nil

        switch result {
        case .failure(let error):
            state.failedPage = requestedPage
            state.error = error

        case .success(let page):
            guard page.page == requestedPage else {
                state.failedPage = requestedPage
                state.error = .invalidResponse
                publish()
                return
            }
            if requestedPage == 1 {
                state.items = Self.uniqueItems(page.items)
            } else {
                state.items = Self.uniqueItems(state.items + page.items)
            }
            state.currentPage = requestedPage
            state.totalPages = max(requestedPage, max(1, page.totalPages))
            state.failedPage = nil
            state.error = nil
            state.isShowingCachedContent = false
            storeSnapshot()
        }
        publish()
    }

    private func storeSnapshot() {
        cache.store(
            CloudStorageGalleryCacheSnapshot(
                items: state.items,
                currentPage: state.currentPage,
                totalPages: state.totalPages
            ),
            for: cacheKey
        )
    }

    private func publish() {
        onStateChange?(state)
    }

    private static func uniqueItems(_ items: [NSDictionary]) -> [NSDictionary] {
        var seen = Set<String>()
        return items.filter { item in
            guard let identity = identity(for: item) else { return true }
            return seen.insert(identity).inserted
        }
    }

    private static func identity(for item: NSDictionary) -> String? {
        guard let fileID = fileID(from: item["id"]) else { return nil }
        return "id:\(fileID)"
    }

    private static func fileID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
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
