//
//  CloudStorageGalleryViewController.swift
//  xabber
//
//  Created by MacIntel on 27.09.2023.
//  Copyright © 2023 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack
import MaterialComponents.MDCPalettes

class CloudStorageGalleryViewController: CloudStorageShowFilesViewController {
    let selectedType: MimeIconTypes
    var datasource: [CloudStorageShowFilesViewController.Datasource] = []
    var images: [CloudStorageShowFilesViewController.Datasource] = []
    var optionButton: UIBarButtonItem? = nil
    var cancelSelectButton: UIBarButtonItem? = nil
    var deleteSelectedFilesButton: UIBarButtonItem? = nil
    var infoVCDelegate: InfoVCDelegate? = nil
    var isSelectModeEnabled: Bool = false
    let impactFeedbackGenerator: UIImpactFeedbackGenerator
    
    @objc func optionButtonTapped() {
        let viewController = UIViewController()
        let tableView = UITableView()
        tableView.backgroundColor = .incomingGray
        viewController.view.addSubview(tableView)
        tableView.fillSuperview()
        viewController.modalPresentationStyle = .popover
        viewController.preferredContentSize = CGSize(width: 150, height: 44)
        tableView.dataSource = self
        tableView.delegate = self

        guard let presentationVC = viewController.popoverPresentationController else { return }
        presentationVC.permittedArrowDirections = []
        presentationVC.delegate = self

        if #available(iOS 16.0, *) {
            presentationVC.sourceItem = optionButton
        } else {
            presentationVC.barButtonItem = optionButton
        }
        presentationVC.sourceRect = CGRect(width: 150, height: 44)

        present(viewController, animated: true)
    }
    

    @objc func cancelSelectButtonTapped() {
        switch selectedType {
        case .image:
            self.navigationItem.title = "Images"
        case .audio:
            self.navigationItem.title = "Voice"
        case .video:
            self.navigationItem.title = "Videos"
        case .avatar:
            self.navigationItem.title = "Avatars"
        default:
            self.navigationItem.title = "Files"
        }
        
        navigationItem.setRightBarButton(optionButton, animated: true)
        navigationItem.hidesBackButton = false
        navigationItem.setLeftBarButton(nil, animated: true)
        collectionView.isEditing = false
        collectionView.reloadData()
    }
    
    @objc func deleteSelectedFilesButtonTapped() {
        ActionSheetPresenter()
            .present(in: self,
                     title: "Delete files",
                     message: "Please confirm deleting files from a cloud storage. This action can not be undone.",
                     cancel: "Cancel",
                     values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
                     animated: true){ _ in
                if self.selectedType == .avatar {
                    self.collectionView.indexPathsForSelectedItems?.forEach { indexPathForSelectedFile in
                        guard let fileId = self.datasource[indexPathForSelectedFile.row].fileId else {
                            return
                        }
                        AccountManager.shared.find(for: self.owner)?.action({ user, _ in
                            user.cloudStorage.deleteAvatarFromServer(fileID: fileId)
                        })
                    }
                } else {
                    self.collectionView.indexPathsForSelectedItems?.forEach { indexPathForSelectedFile in
                        guard let fileId = self.datasource[indexPathForSelectedFile.row].fileId else {
                            return
                        }
                        AccountManager.shared.find(for: self.owner)?.action({ user, _ in
                            user.cloudStorage.deleteMediaFromServer(fileID: fileId)
                        })
                    }
                }
                self.navigationController?.popViewController(animated: true)
                let lastViewController = self.navigationController?.visibleViewController as! CloudStorageViewController
                lastViewController.tableView.reloadData()
            }
    }
    
    @objc func longPressGesture(_ gestureRecognizer: UILongPressGestureRecognizer) {
        if collectionView.isEditing {
            return
        }
        impactFeedbackGenerator.impactOccurred()
        impactFeedbackGenerator.prepare()
        self.navigationItem.title = "1 \(selectedType)s selected"
        let touchPoint = gestureRecognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: touchPoint) else { return }
        cancelSelectButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelSelectButtonTapped))
        deleteSelectedFilesButton = UIBarButtonItem(image: imageLiteral( "trash-outline"), style: .plain, target: self, action: #selector(deleteSelectedFilesButtonTapped))
        navigationItem.hidesBackButton = true
        navigationItem.setRightBarButton(deleteSelectedFilesButton, animated: true)
        navigationItem.setLeftBarButton(cancelSelectButton, animated: true)
        setEditing(true, animated: true)
        collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
        return
    }
    
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
    
    init(selectedType: MimeIconTypes, owner: String) {
        impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .rigid)
        self.selectedType = selectedType
        super.init(owner: owner)
        AccountManager.shared.find(for: self.owner)?.action({ user, _ in
            if self.selectedType == .avatar {
                user.cloudStorage.getAvatars(page: 1) { items, totalObjects, objPerPage, totalPages in
                    if items.isEmpty {
                        DispatchQueue.main.async {
                            self.spinner.removeFromSuperview()
                            self.spinner.stopAnimating()
                            self.configureCollections()
                        }
                        return
                    }
                    
                    self.totalPages = totalPages
                    self.items = items
                    if totalPages == 1 {
                        DispatchQueue.main.async {
                            self.spinner.removeFromSuperview()
                            self.spinner.stopAnimating()
                            self.configureCollections()
                        }
                    } else {
                        for page in 2..<totalPages + 1 {
                            user.cloudStorage.getAvatars(page: page) { items, totalObjects, objPerPage, pages in
                                DispatchQueue.main.async {
                                    if items.isEmpty {
                                        return
                                    }
                                    self.items += items
                                    self.spinner.removeFromSuperview()
                                    self.spinner.stopAnimating()
                                    self.configureCollections()
                                }
                            }
                        }
                    }
                }
                return
            } else {
                user.cloudStorage.getFilesOfType(type: selectedType, page: 1) { items, totalObjects, objPerPage, totalPages in
                    if items.isEmpty {
                        DispatchQueue.main.async {
                            self.spinner.removeFromSuperview()
                            self.spinner.stopAnimating()
                            self.configureCollections()
                        }
                        return
                    }
                    self.totalPages = totalPages
                    self.items = items
                    if totalPages == 1 {
                        DispatchQueue.main.async {
                            self.spinner.removeFromSuperview()
                            self.spinner.stopAnimating()
                            self.configureCollections()
                        }
                    } else {
                        for page in 2..<totalPages + 1 {
                            user.cloudStorage.getFilesOfType(type: selectedType, page: page) { items, totalObjects, objPerPage, pages in
                                DispatchQueue.main.async {
                                    if items.isEmpty {
                                        return
                                    }
                                    self.items += items
                                    self.spinner.removeFromSuperview()
                                    self.spinner.stopAnimating()
                                    self.configureCollections()
                                }
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
    
    func configureCollections() {
        if items.isEmpty {
            datasource.append(Datasource(kind: .undefined))
        }
        switch selectedType {
        case .image:
            self.navigationItem.title = "Images"
            items.forEach { item in
                let url = item["file"] as? String
                
                let createdAt = item["created_at"] as? String
                var date: Date? = nil
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                date = dateFormatter.date(from: createdAt ?? "")
                
                datasource.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                             kind: .image,
                                             mimeType: item["media_type"] as? String,
                                             dateFormatted: date,
                                             fileId: item["id"] as? Int))
            }
        case .video:
            self.navigationItem.title = "Videos"
            items.forEach { item in
                let url = item["file"] as? String
                let metadata = item["metadata"] as? NSDictionary
                let videoDuration = metadata?["duration"] as? String
                let videoPreviewKey = metadata?["video_preview_key"] as? String
                
                let createdAt = item["created_at"] as? String
                var date: Date? = nil
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                date = dateFormatter.date(from: createdAt ?? "")
                
                datasource.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                             kind: .video,
                                             videoPreviewKey: videoPreviewKey,
                                             videoDuration: videoDuration,
                                             mimeType: item["media_type"] as? String,
                                             dateFormatted: date,
                                             fileId: item["id"] as? Int))
            }
        case .audio:
            self.navigationItem.title = "Voice messages"
            items.forEach { item in
                let url = item["file"] as? String
                
                let metadata = item["metadata"] as? NSDictionary
                let audioDuration = metadata?["duration"] as? String
                let meters = metadata?["meters"] as? String
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                guard let createdAt = item["created_at"] as? String,
                      let dateToSort = dateFormatter.date(from: createdAt) else {
                    return
                }
                
                let dateAndTime = PhotoGallery.prepareDate(date: dateToSort)
                let date = dateAndTime.date
                let time = dateAndTime.send_time
                
                guard let fileSizeBytes = item["size"] else { return }
                let fileSize = AccountQuotaStorageItem.beautify(size: fileSizeBytes as! Int)
                
                datasource.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                            kind: .voice,
                                            audioDuration: audioDuration,
                                            meters: meters,
                                            mimeType: item["media_type"] as? String,
                                            fileName: item["name"] as? String,
                                            dateFormatted: dateToSort,
                                            date: date,
                                            time: time,
                                            size: fileSize,
                                            fileId: item["id"] as? Int))
            }
        case .avatar:
            self.navigationItem.title = "Avatars"
            items.forEach { item in
                let url = item["file"] as? String
                
                let createdAt = item["created_at"] as? String
                var date: Date? = nil
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                date = dateFormatter.date(from: createdAt ?? "")
                
                datasource.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                             kind: .avatar,
                                             mimeType: item["media_type"] as? String,
                                             dateFormatted: date,
                                             fileId: item["id"] as? Int))
            }
        default:
            self.navigationItem.title = "Files"
            items.forEach { item in
                let url = item["file"] as? String
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                guard let createdAt = item["created_at"] as? String,
                      let dateToSort = dateFormatter.date(from: createdAt) else {
                    return
                }
                
                let dateAndTime = PhotoGallery.prepareDate(date: dateToSort)
                let date = dateAndTime.date
                let time = dateAndTime.send_time
                
                guard let fileSizeBytes = item["size"] else { return }
                let fileSize = AccountQuotaStorageItem.beautify(size: fileSizeBytes as! Int)
                
                datasource.append(Datasource(uri: url?.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                                            kind: .file,
                                            mimeType: item["media_type"] as? String,
                                            fileName: item["name"] as? String,
                                            dateFormatted: dateToSort,
                                            date: date,
                                            time: time,
                                            size: fileSize,
                                            fileId: item["id"] as? Int))
            }
        }
        
        datasource.sort(by: { $0.dateFormatted! > $1.dateFormatted! })
        optionButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle")!.withRenderingMode(.alwaysTemplate), style: .plain, target: self, action: #selector(optionButtonTapped))
        if items.isEmpty {
            optionButton?.isEnabled = false
        }
        navigationItem.setRightBarButton(optionButton, animated: false)
        
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.allowsMultipleSelection = true
        infoVCDelegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if CommonConfigManager.shared.config.use_large_title {
            self.navigationItem.largeTitleDisplayMode = .automatic
        } else {
            self.navigationItem.largeTitleDisplayMode = .never
        }
        self.navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        view.backgroundColor = .systemGroupedBackground
        spinner.startAnimating()
        view.addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        impactFeedbackGenerator.prepare()
        
        if datasource.isNotEmpty && spinner.isAnimating {
            spinner.removeFromSuperview()
            spinner.stopAnimating()
        }
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = true
        collectionView.reloadData()
    }
}

extension CloudStorageGalleryViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return datasource.count
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = datasource[indexPath.row]
        if item.kind == .undefined {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoFilesMediaCollectionCell.cellName, for: indexPath) as! NoFilesMediaCollectionCell
            cell.setup()
            if selectedType == .audio {
                cell.label.text = "No voice messages"
            } else {
                cell.label.text = "No \(selectedType.rawValue)s"
            }
            return cell
        }
        switch selectedType {
        case .image, .avatar:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as! PhotosMediaCollectionCell
            cell.setup(photoUrls: (thumb: item.thumbnail, url: item.uri!))
            if collectionView.isEditing {
                if cell.isSelected {
                    cell.select()
                } else {
                    cell.deselect()
                }
                cell.editModeEnabled()
            } else {
                if cell.contentView.gestureRecognizers?.count ?? 0 <= 1 {
                    cell.contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressGesture(_:))))
                }
                cell.editModeDisabled()
            }
            return cell
        case .video:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideosMediaCollectionCell.cellName, for: indexPath) as! VideosMediaCollectionCell
            cell.setup(videoCacheKey: item.videoPreviewKey, videoDuration: item.videoDuration ?? "")
            if collectionView.isEditing {
                if cell.isSelected {
                    cell.select()
                } else {
                    cell.deselect()
                }
                cell.editModeEnabled()
            } else {
                cell.contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressGesture(_:))))
                cell.editModeDisabled()
            }
            return cell
        case .audio:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
//            cell.setup(withReference: item.voiceModel, date: item.date!, send_time: item.time!, sizeInBytes: item.size!, url: item.uri)
            if item.meters == nil {
                cell.audioView.configure(.paused, meters: [0.0, 0.0], loading: false, duration: item.audioDuration ?? "", senderName: item.fileName ?? "Audio message", date: item.date!, send_time: item.time!, sizeInBytes: item.size ?? "? КБ")
            }
            cell.audioView.durationLabel.text = cell.sizeInBytes
            if indexPath.row == datasource.count - 1 {
                cell.audioView.separatorLine.isHidden = true
            }
            if collectionView.isEditing {
                if cell.isSelected {
                    if indexPath.item > 0 {
                        let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? VoiceMediaCollectionCell
                        lastCell?.audioView.separatorLine.isHidden = true
                    }
                    cell.select()
                } else {
                    if indexPath.item > 0 {
                        let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? VoiceMediaCollectionCell
                        lastCell?.audioView.separatorLine.isHidden = false
                    }
                    cell.deselect()
                }
            } else {
                if cell.contentView.gestureRecognizers?.count ?? 0 <= 1 {
                    cell.contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressGesture(_:))))
                }
                cell.bringSubviewToFront(cell.contentView)
                if indexPath.item > 0 {
                    let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? VoiceMediaCollectionCell
                    lastCell?.audioView.separatorLine.isHidden = false
                }
                cell.editModeDisabled()
            }
            return cell
        default:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilesMediaCollectionCell.cellName, for: indexPath) as! FilesMediaCollectionCell
            cell.setup(mimeType: item.mimeType ?? "file", sender: item.senderName ?? "", date: item.date ?? "", time: item.time ?? "", sizeInBytes: String(item.size!), filename: item.fileName ?? "")
            
            cell.senderNameLabel.text = cell.fileNameLabel.text
            cell.fileNameLabel.isHidden = true
            cell.fileSizeLabel.text = item.size
            if indexPath.row == datasource.count - 1 {
                cell.separatorLine.isHidden = true
            }
            if collectionView.isEditing {
                if cell.isSelected {
                    if indexPath.item > 0 {
                        let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? FilesMediaCollectionCell
                        lastCell?.separatorLine.isHidden = true
                    }
                    cell.select()
                } else {
                    if indexPath.item > 0 {
                        let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? FilesMediaCollectionCell
                        lastCell?.separatorLine.isHidden = false
                    }
                    cell.deselect()
                }
            } else {
                if cell.contentView.gestureRecognizers?.count ?? 0 <= 1 {
                    cell.contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressGesture(_:))))
                }
                if indexPath.item > 0 {
                    let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? FilesMediaCollectionCell
                    lastCell?.separatorLine.isHidden = false
                }
                cell.editModeDisabled()
            }
            return cell
        }
    }
}

extension CloudStorageGalleryViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        if items.isEmpty {
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 60)
        }
        switch selectedType {
        case .image, .video, .avatar:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = InfoScreenFooterView.cellSpacing
            layout.minimumInteritemSpacing = InfoScreenFooterView.cellSpacing
            collectionView.collectionViewLayout = layout
            let widthRaw = view.frame.width / InfoScreenFooterView.numberOfCells - InfoScreenFooterView.cellSpacing * (InfoScreenFooterView.numberOfCells + 1) / InfoScreenFooterView.numberOfCells
            let width = floor(widthRaw * 100) / 100
            return CGSize(square: width)
            
        default:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            collectionView.collectionViewLayout = layout
            return CGSize(width: view.frame.width - InfoScreenFooterView.cellSpacing * 2, height: 60)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView.isEditing {
            if !deleteSelectedFilesButton!.isEnabled {
                deleteSelectedFilesButton?.isEnabled = true
            }
            self.navigationItem.title = "\(collectionView.indexPathsForSelectedItems?.count ?? 0) \(selectedType)s selected"
            switch selectedType {
            case .image, .avatar:
                guard let cell = collectionView.cellForItem(at: indexPath) as? PhotosMediaCollectionCell else { return }
                cell.select()
                return
            case .video:
                guard let cell = collectionView.cellForItem(at: indexPath) as? VideosMediaCollectionCell else { return }
                cell.select()
                return
            case .audio:
                guard let cell = collectionView.cellForItem(at: indexPath) as? VoiceMediaCollectionCell else { return }
                cell.select()
                return
            default:
                guard let cell = collectionView.cellForItem(at: indexPath) as? FilesMediaCollectionCell else { return }
                cell.select()
                guard let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? FilesMediaCollectionCell else { return }
                lastCell.separatorLine.isHidden = true
                return
            }
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        switch selectedType {
        case .image, .avatar:
            let imageUrls: [URL] = datasource.compactMap({ URL(string: $0.uri!) })
            let senders: [String] = datasource.compactMap({ $0.senderName })
            let dates: [String] = datasource.compactMap({ $0.date })
            let times: [String] = datasource.compactMap({ $0.time })
            let messageIds: [String] = datasource.compactMap({ $0.messageId})
            
            self.infoVCDelegate?.presentPhotoGallery(urls: imageUrls, senders: senders, dates: dates, times: times, messageIds: messageIds, page: indexPath.item)
        default:
            return
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.indexPathsForSelectedItems?.count == 0 {
            deleteSelectedFilesButton?.isEnabled = false
        }
        self.navigationItem.title = "\(collectionView.indexPathsForSelectedItems?.count ?? 0) \(selectedType)s selected"
        switch selectedType {
        case .image, .avatar:
            guard let cell = collectionView.cellForItem(at: indexPath) as? PhotosMediaCollectionCell else { return }
            cell.deselect()
            return
        case .video:
            guard let cell = collectionView.cellForItem(at: indexPath) as? VideosMediaCollectionCell else { return }
            cell.deselect()
        case .audio:
            guard let cell = collectionView.cellForItem(at: indexPath) as? VoiceMediaCollectionCell else { return }
            cell.deselect()
        default:
            guard let cell = collectionView.cellForItem(at: indexPath) as? FilesMediaCollectionCell else { return }
            cell.deselect()
            guard let lastCell = collectionView.cellForItem(at: IndexPath(item: indexPath.item - 1, section: indexPath.section)) as? FilesMediaCollectionCell else { return }
            lastCell.separatorLine.isHidden = false
        }
    }
}

extension CloudStorageGalleryViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}

extension CloudStorageGalleryViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        let label = UILabel()
        label.text = "Select files"
        label.font = UIFont.preferredFont(forTextStyle: .body)
        cell.addSubview(label)
        label.fillSuperviewWithOffset(top: 0, bottom: 0, left: 15, right: 0)
        return cell
    }
}

extension CloudStorageGalleryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        dismiss(animated: false)
        self.navigationItem.title = "0 \(selectedType)s selected"
        cancelSelectButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelSelectButtonTapped))
        deleteSelectedFilesButton = UIBarButtonItem(image: imageLiteral( "trash-outline"), style: .plain, target: self, action: #selector(deleteSelectedFilesButtonTapped))
        deleteSelectedFilesButton?.isEnabled = false
        navigationItem.hidesBackButton = true
        navigationItem.setRightBarButton(deleteSelectedFilesButton, animated: true)
        navigationItem.setLeftBarButton(cancelSelectButton, animated: true)
        setEditing(true, animated: true)
    }
}

extension CloudStorageGalleryViewController: InfoVCDelegate {
    func presentVC(vc: UIViewController) {
        present(vc, animated: true)
    }
    
    func presentYesNoPresenter(with url: URL) {
        YesNoPresenter().present(in: self, title: "Open this file".localizeString(id: "open_file_message", arguments: []), message: url.lastPathComponent, yesText: "Open", noText: "Cancel", animated: true) { (value) in
            if value {
                UIApplication.shared.open(url, options: [:]) { (_) in }
            }
        }
    }
    
    func presentPhotoGallery(urls: [URL], senders: [String], dates: [String], times: [String], messageIds: [String], page: Int) {
//        let gallery = CloudPhotoGallery(urls: urls, senders: senders, dates: dates, times: times, messageIds: messageIds)
//        gallery.setPage(page: page)
//        gallery.setupDelegate(photoGalleryDelegate: self)
//        
//        let navigationViewController = UINavigationController(rootViewController: gallery)
//        navigationViewController.modalPresentationStyle = .overFullScreen
//        
//        present(navigationViewController, animated: true)
    }
    
    func scrollToMediaGallery() {
    }
}
