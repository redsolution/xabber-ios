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
            isSensitiveRevealed: Bool
        ) {
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
    
    internal var datasource: [Datasource] = []
    internal var revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    var messageNavigationRouter: MediaGalleryMessageNavigationRouting = MediaGalleryMessageNavigationRouter.shared
    
    open var kind: MessageMediaAttachmentStorageItem.Kind = .file
    open var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
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
