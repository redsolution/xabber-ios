//
//  CloudStorageDeleteViewController.swift
//  xabber
//
//  Created by MacIntel on 11.08.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack

class CloudStorageDeleteViewController: CloudStorageShowFilesViewController {
    var dateOfLastFile: String? = nil
    var datasource: [[Datasource]] = []
    let percent: Int
    
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
        collection.backgroundColor = .systemGroupedBackground
        
        return collection
    }()
    
    init(percent: Int, owner: String, items: [NSDictionary], totalPages: Int) {
        self.percent = percent
        super.init(owner: owner, items: items, totalPages: totalPages)
        
        spinner.startAnimating()
        view.addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            if totalPages == 1 {
                DispatchQueue.main.async {
                    self.spinner.removeFromSuperview()
                    self.spinner.stopAnimating()
                    self.configureCollections()
                }
            } else {
                for page in 2..<totalPages + 1 {
                    user.cloudStorage.getFilesToDeleteByPercent(percent: percent, page: page) { items, totalObjects, objPerPage, pages in
                        if items.isEmpty {
                            return
                        }
                        DispatchQueue.main.async {
                            self.items += items
                            if page == pages {
                                self.spinner.removeFromSuperview()
                                self.spinner.stopAnimating()
                                self.configureCollections()
                                self.collectionView.reloadData()
                            }
                        }
                    }
                }
            }
        })        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func configureCollections() {
        if items.isEmpty {
            return
        }
        
        let date = DateFormatter()
        date.dateFormat = "dd.MM.YYYY H:mm:ss"
        dateOfLastFile = items[0]["created_at"] as? String
        
        var images: [Datasource] = []
        var videos: [Datasource] = []
        var files: [Datasource] = []
        var voices: [Datasource] = []

        items.forEach { item in
            let url = item["file"] as? String
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            guard let createdAt = item["created_at"] as? String,
                  let dateToSort = dateFormatter.date(from: createdAt) else {
                return
            }
            
            var mediaType: String?
            let fileMimeIconType: MimeIconTypes
            if let type = item["media_type"] as? String
            {
                if type.contains(";") {
                    mediaType = String(type.prefix(upTo: type.firstIndex(of: ";")!))
                } else {
                    mediaType = type
                }
                fileMimeIconType = mimeIcon[mediaType!] ?? .file
            } else {
                fileMimeIconType = .file
            }
            
            switch fileMimeIconType {
            case .image:
                images.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                         kind: .image,
                                         mimeType: "image",
                                         dateFormatted: dateToSort,
                                         fileId: item["id"] as? Int))
            case .video:
                let metadata = item["metadata"] as? NSDictionary
                let videoDuration = metadata?["duration"] as? String
                let videoPreviewKey = metadata?["video_preview_key"] as? String
                
                videos.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                         kind: .video,
                                         videoPreviewKey: videoPreviewKey,
                                         videoDuration: videoDuration,
                                         mimeType: "video",
                                         dateFormatted: dateToSort,
                                         fileId: item["id"] as? Int))
            case .audio:
                let metadata = item["metadata"] as? NSDictionary
                let audioDuration = metadata?["duration"] as? String
                let meters = metadata?["meters"] as? String
                
                let dateAndTime = PhotoGallery.prepareDate(date: dateToSort)
                let date = dateAndTime.date
                let time = dateAndTime.send_time
                
                guard let fileSizeBytes = item["size"] else { return }
                let fileSize = AccountQuotaStorageItem.beautify(size: fileSizeBytes as! Int)
                
                voices.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                         kind: .voice,
                                         audioDuration: audioDuration,
                                         meters: meters,
                                         mimeType: "voice",
                                         fileName: item["name"] as? String,
                                         dateFormatted: dateToSort,
                                         date: date,
                                         time: time,
                                         size: fileSize,
                                         fileId: item["id"] as? Int))
                break
                
            default:
                let dateAndTime = PhotoGallery.prepareDate(date: dateToSort)
                let date = dateAndTime.date
                let time = dateAndTime.send_time
                
                guard let fileSizeBytes = item["size"] else { return }
                let fileSize = AccountQuotaStorageItem.beautify(size: fileSizeBytes as! Int)
                
                files.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                        kind: .file,
                                        mimeType: "file",
                                        fileName: item["name"] as? String,
                                        dateFormatted: dateToSort,
                                        date: date,
                                        time: time,
                                        size: fileSize,
                                        fileId: item["id"] as? Int))
                break
            }
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
        spinner.removeFromSuperview()
        spinner.stopAnimating()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        view.backgroundColor = .systemGroupedBackground
        
        self.navigationItem.title = "Delete files"
        if CommonConfigManager.shared.config.use_large_title {
            self.navigationItem.largeTitleDisplayMode = .automatic
        } else {
            self.navigationItem.largeTitleDisplayMode = .never
        }
        self.navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if datasource.isNotEmpty && spinner.isAnimating {
            spinner.removeFromSuperview()
            spinner.stopAnimating()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationItem.title = ""
//        self.navigationController?.navigationBar.prefersLargeTitles = false
    }
}
