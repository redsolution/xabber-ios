//
//  CloudStorageDeleteViewController.swift
//  xabber
//
//  Created by MacIntel on 11.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import TOInsetGroupedTableView
import RxSwift
import CocoaLumberjack

class CloudStorageDeleteViewController: BaseViewController {
    struct Datasource {
        enum Kind {
            case image
            case video
            case file
            case voice
            case undefined
        }
        
        var uri: String? = nil
        var thumbnail: String? = nil
        var kind: Kind
        var videoPreviewKey: String? = nil
        var video_duration: String? = nil
        var mimeType: String? = nil
        var fileName: String? = nil
        var voiceModel: MessageReferenceStorageItem.Model? = nil
        var date: String? = nil
        var time: String? = nil
        var size: String? = nil
        var senderName: String? = nil
    }
    
    var dateOfLastFile: String? = nil
    
    var percent: Int = 0
    
    var totalPages: Int = 0
    
    var items: [NSDictionary] = []

    var datasource: [[Datasource]] = []
    
    var currentPage: Int = 1
    
    lazy var spinner: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = UIColor.gray
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        return activityIndicator
    }()
    
    let collectionView: UICollectionView = {
        let collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout.init())
        
        var collectionViewFlowLayout = UICollectionViewFlowLayout()
        collectionViewFlowLayout.sectionInset = UIEdgeInsets(top: 12, left: InfoScreenFooterView.cellSpacing, bottom: 15, right: InfoScreenFooterView.cellSpacing)
        
        collection.collectionViewLayout = collectionViewFlowLayout
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.register(PhotosMediaCollectionCell.self, forCellWithReuseIdentifier: PhotosMediaCollectionCell.cellName)
        collection.register(VideosMediaCollectionCell.self, forCellWithReuseIdentifier: VideosMediaCollectionCell.cellName)
        collection.register(FilesMediaCollectionCell.self, forCellWithReuseIdentifier: FilesMediaCollectionCell.cellName)
        collection.register(VoiceMediaCollectionCell.self, forCellWithReuseIdentifier: VoiceMediaCollectionCell.cellName)
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "headerView")
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "deleteButton")
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "moreButton")
        collection.backgroundColor = .systemGroupedBackground
        
        return collection
    }()
    
    convenience init(percent: Int, owner: String, items: [NSDictionary], totalPages: Int) {
        self.init()
        self.percent = percent
        self.owner = owner
        self.items = items
        self.totalPages = totalPages
    }
    
    internal func configureCollections() {
        var urls: [String] = []
        
        if items.isEmpty {
            return
        }
        
        items.forEach { item in
            urls.append(item["file"] as! String)
        }
        
        let date = DateFormatter()
        date.dateFormat = "dd.MM.YYYY H:mm:ss"
        dateOfLastFile = items[0]["created_at"] as? String
        
        var images: [Datasource] = []
        var videos: [Datasource] = []
        var files: [Datasource] = []
        var voices: [Datasource] = []

        do {
            let realm = try WRealm.safe()

            let predicate = NSPredicate(format: "url IN %@", urls)
            let collection = realm
                .objects(MessageReferenceStorageItem.self)
                .filter(predicate)
                .sorted(byKeyPath: "sentDate", ascending: false)
            collection.forEach { item in
                switch item.mimeType {
                case "image":
                    images.append(Datasource(uri: item.url!,
                                             kind: .image,
                                             mimeType: item.mimeType))
                case "video":
                    videos.append(Datasource(uri: item.url!,
                                             kind: .video,
                                             videoPreviewKey: item.videoPreviewKey,
                                             video_duration: item.video_duration))
                default:
                    if item.kind == .voice {
                        let voiceModel = item.loadModel()
                        let senderData = PhotoGallery.getSenderName(messageId: item.messageId)
                        voices.append(Datasource(uri: item.url!,
                                                 kind: .voice,
                                                 voiceModel: voiceModel,
                                                 date: senderData.date,
                                                 time: senderData.time,
                                                 size: item.sizeInBytes,
                                                 senderName: senderData.senderName))
                        return
                    }
                    let senderData = PhotoGallery.getSenderName(messageId: item.messageId)
                    files.append(Datasource(kind: .file,
                                            mimeType: item.mimeType,
                                            fileName: item.name ?? (item.downloadUrl?.lastPathComponent ?? "File".localizeString(id: "chat_message_file", arguments: [])),
                                            date: senderData.date,
                                            time: senderData.time,
                                            size: item.sizeInBytes,
                                            senderName: senderData.senderName))
                }
            }
        } catch {
            DDLogDebug("InfoScreenFooterView: \(#function). \(error.localizedDescription)")
        }
        
        datasource = []
        datasource.append([])
        
        [images, videos, files, voices].forEach { collection in
            if collection.isNotEmpty {
                datasource.append(collection)
            }
        }
        
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        collectionView.dataSource = self
        collectionView.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        view.backgroundColor = .systemGroupedBackground
        spinner.startAnimating()
        view.addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        
        guard let account = AccountManager.shared.find(for: owner),
              let uploader = account.getDefaultUploader() as? UploadManagerExtendedProtocol else {
            return
        }
        
        for page in 1..<totalPages + 1 {
            uploader.getFilesToDeleteByPercent(percent: percent, page: page) { items, totalObjects, objPerPage, pages in
                if items.isEmpty {
                    return
                }
                self.items += items
                if page == pages {
                    self.spinner.removeFromSuperview()
                    self.spinner.stopAnimating()
                    self.configureCollections()
                    self.collectionView.reloadData()
                }
            }
        }
        
        self.navigationItem.title = "Delete files"
        self.navigationController?.navigationBar.prefersLargeTitles = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationItem.title = ""
        self.navigationController?.navigationBar.prefersLargeTitles = false
    }
}
