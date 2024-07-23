//
//  ChatFilesViewController.swift
//  xabber
//
//  Created by Admin on 22.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import CocoaLumberjack

class ChatFilesViewController: SimpleBaseViewController {
    class Datasource {
        enum Kind {
            case image
            case video
            case file
            case voice
            case undefined
        }
        
        let primary: String
        let jid: String
        let owner: String
        let messageId: String
        let uri: String
        let thumbnail: String?
        let videoPreviewKey: String?
        let videoOrientation: String?
        let voiceModel: MessageReferenceStorageItem.Model?
        let senderName: String
        let date: String
        let send_time: String?
        let sizeInBytes: String?
        let video_duration: String?
        let mimeType: String
        let filename: String
        let referencePrimary: String
        
        init(primary: String, jid: String, owner: String, messageId: String, uri: String, thumbnail: String? = nil, videoPreviewKey: String? = nil, videoOrientation: String? = nil, voiceModel: MessageReferenceStorageItem.Model? = nil, senderName: String, date: String, send_time: String? = nil, sizeInBytes: String? = nil, video_duration: String? = nil, mimeType: String, filename: String, referencePrimary: String) {
            self.primary = primary
            self.jid = jid
            self.owner = owner
            self.messageId = messageId
            self.uri = uri
            self.thumbnail = thumbnail
            self.videoPreviewKey = videoPreviewKey
            self.videoOrientation = videoOrientation
            self.voiceModel = voiceModel
            self.senderName = senderName
            self.date = date
            self.send_time = send_time
            self.sizeInBytes = sizeInBytes
            self.video_duration = video_duration
            self.mimeType = mimeType
            self.filename = filename
            self.referencePrimary = referencePrimary
        }
    }
    
    enum Kind: String {
        case images = "Images"
        case videos = "Videos"
        case files = "Files"
        case voice = "Voice"
    }
    
    var selectedType: Kind? = nil
    var datasource = [Datasource]()
    
    let collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout.init())
        
        var collectionViewflowLayout = UICollectionViewFlowLayout()
        collectionViewflowLayout.sectionInset = UIEdgeInsets(top: 12, left: InfoScreenFooterView.cellSpacing, bottom: 15, right: InfoScreenFooterView.cellSpacing)
        
        view.collectionViewLayout = collectionViewflowLayout
        view.translatesAutoresizingMaskIntoConstraints = false
        
        view.register(PhotosMediaCollectionCell.self, forCellWithReuseIdentifier: PhotosMediaCollectionCell.cellName)
        view.register(VideosMediaCollectionCell.self, forCellWithReuseIdentifier: VideosMediaCollectionCell.cellName)
        view.register(FilesMediaCollectionCell.self, forCellWithReuseIdentifier: FilesMediaCollectionCell.cellName)
        view.register(VoiceMediaCollectionCell.self, forCellWithReuseIdentifier: VoiceMediaCollectionCell.cellName)
        view.register(NoFilesMediaCollectionCell.self, forCellWithReuseIdentifier: NoFilesMediaCollectionCell.cellName)
        view.backgroundColor = .systemGroupedBackground
        return view
    }()
    
    override func subscribe() {
        super.subscribe()
        
        do {
            let realm = try WRealm.safe()
            let collection = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@ AND jid == %@ AND kind_ IN %@ AND hasError == false", self.owner, self.jid, [MessageReferenceStorageItem.Kind.media.rawValue, MessageReferenceStorageItem.Kind.voice.rawValue])
            
            Observable.collection(from: collection).subscribe { results in
                self.loadDatasource()
                self.collectionView.reloadData()
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: bag)

        } catch {
            DDLogDebug("ChatFilesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        collectionView.dataSource = self
        collectionView.delegate = self
    }
    
    override func loadDatasource() {
        var predicate: NSPredicate? = nil
        
        switch selectedType {
        case .images:
            title = "Images"
            predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "image")
            
        case .voice:
            title = "Voices"
            predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND kind_ == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.voice.rawValue)
            
        case .videos:
            title = "Videos"
            predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "video")
            
        default:
            title = "Files"
            let mimeTypes: [String] = ["document", "pdf", "table", "presentation", "archive", "audio", "file"]
            predicate = NSPredicate(format: "owner == %@ AND jid == %@ AND mimeType IN %@ AND hasError == false", self.owner, self.jid, mimeTypes)
            
        }
        
        guard let predicate = predicate else { return }
        
        do {
            let realm = try WRealm.safe()
            let instances = realm.objects(MessageReferenceStorageItem.self).filter(predicate).sorted(byKeyPath: "sentDate", ascending: false)
            
            datasource = instances.compactMap { item in
                guard let uri = item.metadata?["uri"] as? String else {
                    return nil
                }
                
                var voiceModel: MessageReferenceStorageItem.Model? = nil
                if item.kind_ == "voice" {
                    voiceModel = item.loadModel()
                }
                
                let senderData = PhotoGallery.getSenderName(messageId: item.messageId)
                
                return Datasource(
                    primary: item.primary,
                    jid: item.jid,
                    owner: item.owner,
                    messageId: item.messageId,
                    uri: uri,
                    thumbnail: item.metadata?["thumbnail"] as? String,
                    videoPreviewKey: item.videoPreviewKey,
                    videoOrientation: item.videoOrientation,
                    voiceModel: voiceModel,
                    senderName: senderData.senderName,
                    date: senderData.date,
                    send_time: senderData.time,
                    sizeInBytes: item.sizeInBytes,
                    video_duration: item.video_duration,
                    mimeType: item.mimeType,
                    filename: item.name ?? (item.downloadUrl?.lastPathComponent ?? "File"
                        .localizeString(id: "chat_message_file", arguments: [])),
                    referencePrimary: item.primary
                )
            }
            
        } catch {
            DDLogDebug("ChatFilesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func onAppear() {
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
    }
    
}


