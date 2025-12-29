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
            a.url == b.url &&
            a.title == b.title
        }
        
        var kind: MessageMediaAttachmentStorageItem.Kind
        var primary: String
        var title: String
        var subtitle: String
        var url: URL
        var messagePrimary: String
        var isDownloaded: Bool
        var messageId: String
        var thumb: UIImage?
        
        init(kind: MessageMediaAttachmentStorageItem.Kind, primary: String, title: String, subtitle: String, url: URL, messagePrimary: String, isDownloaded: Bool, messageId: String, thumb: UIImage?) {
            self.kind = kind
            self.primary = primary
            self.title = title
            self.url = url
            self.messagePrimary = messagePrimary
            self.isDownloaded = isDownloaded
            self.subtitle = subtitle
            self.messageId = messageId
            self.thumb = thumb
        }
    }
    
    internal var datasource: [Datasource] = []
    
    open var kind: MessageMediaAttachmentStorageItem.Kind = .file
    open var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    open var collectionObserver: Results<MessageMediaAttachmentStorageItem>? = nil
    
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            self.collectionObserver = realm
                .objects(MessageMediaAttachmentStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND conversationType_ == %@ AND kind_ == %@", self.owner, self.jid, self.conversationType.rawValue, self.kind.rawValue)
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
        return results.compactMap {
            item in
            if let url = item.url {
                return Datasource(kind: self.kind, primary: item.primary, title: item.filename, subtitle: item.subtitle(), url: url, messagePrimary: item.messagePrimary, isDownloaded: item.isDownloaded, messageId: item.archiveId, thumb: item.thumb)
            }
            return nil
        }
    }
    
    func compareDatasource(_ newDatasource: [Datasource]) -> [Change<Datasource>] {
        return diff(old: self.datasource, new: newDatasource)
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

        guard let maxRow = indexPaths.compactMap({ $0.row }).max() else { return }
        if maxRow > datasource.count / 2 {
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.mam?.temporaryMessageReceiverDelegate = self
                session.mam?.getMedia(stream, jid: self.jid, conversationType: self.conversationType, media: [self.kind], after: self.datasource.last?.messageId)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.mam.temporaryMessageReceiverDelegate = self
                    user.mam.getMedia(stream, jid: self.jid, conversationType: self.conversationType, media: [self.kind], after: self.datasource.last?.messageId)
                }
            }

        }
    }
    
    
}

extension BaseMediaGalleryForChatViewController: TemporaryMessageReceiverProtocol {
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        
    }
    
    func didReceiveEndPage(queryId: String, fin: Bool, first: String, last: String, count: Int) {
        
    }
}
