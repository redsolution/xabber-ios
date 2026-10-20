//
//  BaseMediaGalleryForChatViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.12.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import Realm
import RealmSwift
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RxSwift
import RxCocoa
import RxRelay
import DeepDiff
import Kingfisher

enum MediaGalleryContextMenuIdentifier {
    static let report = UIAction.Identifier("mediaGallery.report")
}

class BaseMediaGalleryForChatViewController: SimpleBaseViewController {
        
    class Datasource: DiffAware, Equatable, Hashable {
        typealias DiffId = String
        
        var diffId: String {
            get {
                return primary
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.primary == rhs.primary
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(primary)
        }
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.primary == b.primary &&
                a.encryptedAttachment == b.encryptedAttachment &&
                a.kind == b.kind &&
                a.url == b.url &&
                a.filename == b.filename &&
                a.archiveId == b.archiveId &&
                a.messagePrimary == b.messagePrimary &&
                a.byteSize == b.byteSize &&
                a.durationSeconds == b.durationSeconds &&
                a.previewCacheIdentity == b.previewCacheIdentity &&
                a.decodedURL == b.decodedURL &&
                a.isDownloaded == b.isDownloaded &&
                a.pcm == b.pcm &&
                a.verySmallThumb == b.verySmallThumb &&
                a.isSensitive == b.isSensitive &&
                a.isSensitiveRevealed == b.isSensitiveRevealed
        }
        
        let encryptedAttachment: ChatEncryptedAttachmentDescriptor?
        let kind: MessageMediaAttachmentStorageItem.Kind
        let primary: String
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let date: Date
        let filename: String
        let url: URL?
        let messagePrimary: String
        let archiveId: String
        let isDownloaded: Bool
        let verySmallThumb: String?
        let thumb: UIImage?
        let byteSize: Int
        let formattedByteSize: String
        let durationSeconds: TimeInterval?
        let formattedDuration: String?
        let previewURL: URL?
        let previewCacheIdentity: String?
        let mediaType: String?
        let decodedURL: URL?
        let pcm: [Float]
        let isSensitive: Bool
        let isSensitiveRevealed: Bool

        var title: String { filename }
        var subtitle: String { formattedByteSize }
        var messageId: String { archiveId }
        
        init(
            kind: MessageMediaAttachmentStorageItem.Kind,
            primary: String,
            owner: String,
            jid: String,
            conversationType: ClientSynchronizationManager.ConversationType,
            date: Date,
            filename: String,
            url: URL?,
            messagePrimary: String,
            archiveId: String,
            isDownloaded: Bool,
            verySmallThumb: String?,
            thumb: UIImage?,
            byteSize: Int,
            formattedByteSize: String,
            durationSeconds: TimeInterval?,
            formattedDuration: String?,
            previewURL: URL?,
            previewCacheIdentity: String?,
            mediaType: String?,
            decodedURL: URL?,
            pcm: [Float],
            isSensitive: Bool,
            isSensitiveRevealed: Bool,
            encryptedAttachment: ChatEncryptedAttachmentDescriptor? = nil
        ) {
            self.encryptedAttachment = encryptedAttachment
            self.kind = kind
            self.primary = primary
            self.owner = owner
            self.jid = jid
            self.conversationType = conversationType
            self.date = date
            self.filename = filename
            self.url = url
            self.messagePrimary = messagePrimary
            self.archiveId = archiveId
            self.isDownloaded = isDownloaded
            self.verySmallThumb = verySmallThumb
            self.thumb = thumb
            self.byteSize = byteSize
            self.formattedByteSize = formattedByteSize
            self.durationSeconds = durationSeconds
            self.formattedDuration = formattedDuration
            self.previewURL = previewURL
            self.previewCacheIdentity = previewCacheIdentity
            self.mediaType = mediaType
            self.decodedURL = decodedURL
            self.pcm = pcm
            self.isSensitive = isSensitive
            self.isSensitiveRevealed = isSensitiveRevealed
        }
    }
    
    var galleryAttachmentReceive: (ChatEncryptedAttachmentDescriptor, @escaping (Result<ChatAuthenticatedAttachmentFile, ChatEncryptedAttachmentReceiveError>) -> Void) -> ChatEncryptedAttachmentReceiveTask = { descriptor, completion in
        ChatEncryptedAttachmentReceiver.shared.receive(descriptor, completion: completion)
    }
    var mediaGalleryPresentationForTesting: ((ChatMediaOpeningKind, [URL], URL) -> Void)?
    private var galleryMediaGeneration = UUID()
    private var galleryMediaTasks: [ChatEncryptedAttachmentReceiveTask] = []

    override var owner: String { didSet { if owner != oldValue { cancelGalleryMediaOpening() } } }
    override var jid: String { didSet { if jid != oldValue { cancelGalleryMediaOpening() } } }

    func cancelGalleryMediaOpening() {
        galleryMediaGeneration = UUID()
        galleryMediaTasks.forEach { $0.cancel() }
        galleryMediaTasks.removeAll()
    }

    override func viewWillDisappear(_ animated: Bool) {
        cancelGalleryMediaOpening()
        super.viewWillDisappear(animated)
    }

    /// Bind gallery snapshots to the current account and stored reference before
    /// handing any protected bytes to a viewer or a sharing activity.
    private func currentGalleryDescriptor(for item: Datasource) -> ChatEncryptedAttachmentDescriptor? {
        guard item.owner == owner, item.jid == jid, item.conversationType == conversationType,
              let source = item.url else { return nil }
        do {
            let realm = try WRealm.safe()
            guard !realm.isInWriteTransaction else { return nil }
            realm.refresh()
            if let reference = realm.object(ofType: MessageReferenceStorageItem.self, forPrimaryKey: item.primary) {
                guard reference.owner == owner, reference.jid == jid, reference.conversationType == conversationType,
                      [.media, .voice].contains(reference.kind), reference.downloadUrl == source else { return nil }
                return ChatEncryptedAttachmentDescriptor(metadata: reference.metadata, url: source,
                    owner: owner, referenceIdentity: item.primary)
            }
            if let stored = realm.object(ofType: MessageMediaAttachmentStorageItem.self, forPrimaryKey: item.primary) {
                guard stored.owner == owner, stored.jid == jid, stored.conversationType == conversationType,
                      stored.kind == item.kind, stored.url == source, !stored.isLocallyHiddenByReport else { return nil }
                return MediaGalleryDatasourceMapper.attachmentDescriptor(for: stored)
            }
        } catch { return nil }
        // Existing unencrypted, nonpersisted gallery items keep their ordinary route.
        guard item.encryptedAttachment == nil, !conversationType.isEncrypted else { return nil }
        return ChatEncryptedAttachmentDescriptor(metadata: nil, url: source, owner: owner, referenceIdentity: item.primary)
    }

    func resolveGalleryMedia(_ items: [Datasource], selectedPrimary: String,
                             completion: @escaping ([URL], URL) -> Void) {
        cancelGalleryMediaOpening()
        guard !items.isEmpty, let selected = items.firstIndex(where: { $0.primary == selectedPrimary }) else { return }
        var descriptors: [ChatEncryptedAttachmentDescriptor] = []
        for item in items {
            guard let descriptor = currentGalleryDescriptor(for: item), descriptor.state != .invalid,
                  item.encryptedAttachment == nil || item.encryptedAttachment == descriptor else { return }
            descriptors.append(descriptor)
        }
        var resolved = items.compactMap(\.url)
        guard resolved.count == items.count else { return }
        let generation = galleryMediaGeneration, capturedOwner = owner, capturedJid = jid, capturedType = conversationType
        let current: (BaseMediaGalleryForChatViewController) -> Bool = { controller in
            controller.galleryMediaGeneration == generation && controller.owner == capturedOwner &&
                controller.jid == capturedJid && controller.conversationType == capturedType &&
                zip(items, descriptors).allSatisfy { item, descriptor in controller.currentGalleryDescriptor(for: item) == descriptor }
        }
        var remaining = descriptors.filter(\.requiresAuthentication).count
        guard remaining > 0 else { completion(resolved, resolved[selected]); return }
        var completed = Set<Int>()
        for (index, descriptor) in descriptors.enumerated() where descriptor.requiresAuthentication {
            guard galleryMediaGeneration == generation else { break }
            let task = galleryAttachmentReceive(descriptor) { [weak self] result in
                guard let self, self.galleryMediaGeneration == generation, !completed.contains(index) else { return }
                guard current(self), case let .success(file) = result,
                      file.fileURL.isFileURL, FileManager.default.fileExists(atPath: file.fileURL.path),
                      file.cacheIdentity == descriptor.cacheIdentity else { self.cancelGalleryMediaOpening(); return }
                completed.insert(index); resolved[index] = file.fileURL; remaining -= 1
                guard remaining == 0 else { return }
                self.galleryMediaTasks.removeAll()
                self.galleryMediaGeneration = UUID()
                completion(resolved, resolved[selected])
            }
            if galleryMediaGeneration == generation { galleryMediaTasks.append(task) } else { task.cancel() }
        }
    }

    var canPresentGalleryMedia: Bool {
        if mediaGalleryPresentationForTesting != nil { return true }
        guard viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return false }
        var context: UIViewController? = self
        while let controller = context {
            guard controller.presentedViewController == nil, !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            context = controller.parent
        }
        return true
    }

    deinit { galleryMediaTasks.forEach { $0.cancel() } }

    internal var datasource: [Datasource] = []
    internal var revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    var messageNavigationRouter: MediaGalleryMessageNavigationRouting = MediaGalleryMessageNavigationRouter.shared
    
    open var kind: MessageMediaAttachmentStorageItem.Kind = .file
    open var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular {
        didSet { if conversationType != oldValue { cancelGalleryMediaOpening() } }
    }
    open var collectionObserver: Results<MessageMediaAttachmentStorageItem>? = nil
    
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            self.collectionObserver = realm
                .objects(MessageMediaAttachmentStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND conversationType_ == %@ AND kind_ == %@ AND isLocallyHiddenByReport == false", self.owner, self.jid, self.conversationType.rawValue, self.kind.rawValue)
                .sorted(by: [SortDescriptor(keyPath: "date", ascending: false)])
        } catch {
            DDLogDebug("MediaGalleryForChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func subscribe() {
        super.subscribe()
        guard self.collectionObserver != nil else {
            return
        }
        self.apply(self.mapDataset(self.collectionObserver!))
        Observable
            .collection(from: self.collectionObserver!, synchronousStart: true)
            .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { results in
                self.apply(self.mapDataset(results))
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }
            .disposed(by: self.bag)

    }
    
    func mapDataset(_ results: Results<MessageMediaAttachmentStorageItem>) -> [Datasource] {
        return results.map { item in
            MediaGalleryDatasourceMapper.map(
                item,
                revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries
            )
        }
    }
    
    func compareDatasource(_ newDatasource: [Datasource]) -> [Change<Datasource>] {
        return diff(old: self.datasource, new: newDatasource)
    }

    func canOpenContainingMessage(for item: Datasource) -> Bool {
        MediaGalleryMessageNavigationRequestBuilder.request(for: item) != nil
    }

    @discardableResult
    func openContainingMessage(
        for item: Datasource
    ) -> MediaGalleryMessageNavigationRouteResult {
        guard let request = MediaGalleryMessageNavigationRequestBuilder.request(for: item) else {
            return .unavailable
        }
        return messageNavigationRouter.route(request, from: self)
    }

    @available(iOS 13.0, *)
    func contextMenuActions(for item: Datasource) -> [UIMenuElement] {
        [
            UIAction(
                title: "Report Media".localizeString(id: "report_media_action", arguments: []),
                image: UIImage(systemName: "exclamationmark.circle"),
                identifier: MediaGalleryContextMenuIdentifier.report,
                handler: { [weak self] _ in
                    self?.presentReportMedia(primary: item.primary)
                }
            )
        ]
    }
    
    func apply(_ newDatasource: [Datasource]) {
        
    }
    
    override func setupSubviews() {
        super.setupSubviews()
    }
    
    override func configure() {
        super.configure()
    }
    
}


extension BaseMediaGalleryForChatViewController: UICollectionViewDelegate {
    func presentReportMedia(primary: String) {
        let vc = AbuseReportViewController()
        vc.configureMediaReport(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            mediaAttachmentPrimary: primary
        )
        showModal(vc, parent: self)
    }

    @available(iOS 13.0, *)
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard datasource.indices.contains(indexPath.row) else {
            return nil
        }
        let item = datasource[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: self?.contextMenuActions(for: item) ?? [])
        }
    }
    
}

extension BaseMediaGalleryForChatViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return self.datasource.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        fatalError()
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        
    }
}

extension BaseMediaGalleryForChatViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let validRows = indexPaths
            .map(\.row)
            .filter { datasource.indices.contains($0) }
        guard let maxRow = validRows.max() else { return }
        if maxRow > datasource.count / 2 {
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: { [weak self] item, queryId in
                    self?.didReceiveMessage(item, queryId: queryId)
                },
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            _ = AccountManager.shared.find(for: self.owner)?.mam.scheduleMedia(
                jid: self.jid,
                conversationType: self.conversationType,
                media: [self.kind],
                after: self.datasource.last?.messageId,
                requestCallbacks: requestCallbacks
            )

        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {}
}

extension BaseMediaGalleryForChatViewController {
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        
    }
    
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        
    }
}
