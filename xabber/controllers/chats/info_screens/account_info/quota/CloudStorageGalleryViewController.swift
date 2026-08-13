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

struct CloudStorageGallerySelectionReconciliation: Equatable {
    let orderedFileIDs: [Int]
    let indexPaths: [IndexPath]
}

enum CloudStorageGallerySelectionPolicy {
    static func reconcile(
        remainingSelectedFileIDs: Set<Int>,
        datasourceFileIDs: [Int?]
    ) -> CloudStorageGallerySelectionReconciliation {
        var seenFileIDs = Set<Int>()
        var orderedFileIDs: [Int] = []
        var indexPaths: [IndexPath] = []

        for (index, candidate) in datasourceFileIDs.enumerated() {
            guard let fileID = candidate,
                  remainingSelectedFileIDs.contains(fileID),
                  seenFileIDs.insert(fileID).inserted else {
                continue
            }
            orderedFileIDs.append(fileID)
            indexPaths.append(IndexPath(item: index, section: 0))
        }

        return CloudStorageGallerySelectionReconciliation(
            orderedFileIDs: orderedFileIDs,
            indexPaths: indexPaths
        )
    }
}

class CloudStorageGalleryViewController: CloudStorageShowFilesViewController {
    let selectedType: MimeIconTypes
    var datasource: [CloudStorageShowFilesViewController.Datasource] = []
    var images: [CloudStorageShowFilesViewController.Datasource] = []
    var optionButton: UIBarButtonItem? = nil
    var cancelSelectButton: UIBarButtonItem? = nil
    var deleteSelectedFilesButton: UIBarButtonItem? = nil
    var infoVCDelegate: InfoVCDelegate? = nil
    var isSelectModeEnabled: Bool = false
    private var capturedGalleryIdentity: String?
    private var loadError: CloudStorageListLoadError?
    private var remainingSelectedFileIDs = Set<Int>()
    private var isDeletingSelectedFiles = false
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
        guard !isDeletingSelectedFiles else { return }
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
        setEditing(false, animated: true)
    }
    
    @objc func deleteSelectedFilesButtonTapped() {
        guard !isDeletingSelectedFiles else { return }
        let reconciliation = currentSelectionReconciliation()
        remainingSelectedFileIDs = Set(reconciliation.orderedFileIDs)
        let selectedIDs = reconciliation.orderedFileIDs
        guard selectedIDs.isNotEmpty else { return }
        ActionSheetPresenter()
            .present(in: self,
                     title: "Delete files",
                     message: "Please confirm deleting files from a cloud storage. This action can not be undone.",
                     cancel: "Cancel",
                     values: [ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")],
                     animated: true) { [weak self] _ in
                self?.deleteFiles(selectedIDs)
            }
    }

    private func deleteFiles(_ fileIDs: [Int]) {
        guard let account = AccountManager.shared.find(for: owner) else {
            presentDeletionError()
            return
        }
        remainingSelectedFileIDs = Set(fileIDs)
        isDeletingSelectedFiles = true
        deleteSelectedFilesButton?.isEnabled = false
        cancelSelectButton?.isEnabled = false
        collectionView.isUserInteractionEnabled = false
        account.action { [weak self] user, _ in
            guard let self else { return }
            deleteNextFile(
                fileIDs,
                at: 0,
                with: user.cloudStorage,
                isAvatar: selectedType == .avatar
            )
        }
    }

    private func deleteNextFile(
        _ fileIDs: [Int],
        at index: Int,
        with manager: XabberUploadManager,
        isAvatar: Bool
    ) {
        guard fileIDs.indices.contains(index) else {
            DispatchQueue.main.async { [weak self] in
                self?.remainingSelectedFileIDs.removeAll()
                self?.isDeletingSelectedFiles = false
                self?.collectionView.isUserInteractionEnabled = true
                self?.cancelSelectButton?.isEnabled = true
                self?.navigationController?.popViewController(animated: true)
            }
            return
        }
        manager.deleteFile(fileID: fileIDs[index], isAvatar: isAvatar) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                DispatchQueue.main.async {
                    let deletedFileID = fileIDs[index]
                    self.remainingSelectedFileIDs.remove(deletedFileID)
                    self.datasource.removeAll { $0.fileId == deletedFileID }
                    if self.datasource.isEmpty {
                        self.datasource = [Datasource(kind: .undefined)]
                    }
                    self.reloadCollectionRestoringRemainingSelection()
                    self.deleteNextFile(fileIDs, at: index + 1, with: manager, isAvatar: isAvatar)
                }
            case .failure:
                DispatchQueue.main.async {
                    if self.datasource.isEmpty {
                        self.datasource = [Datasource(kind: .undefined)]
                    }
                    self.isDeletingSelectedFiles = false
                    self.collectionView.isUserInteractionEnabled = true
                    self.cancelSelectButton?.isEnabled = true
                    self.reloadCollectionRestoringRemainingSelection()
                    self.presentDeletionError()
                }
            }
        }
    }

    private func currentSelectionReconciliation() -> CloudStorageGallerySelectionReconciliation {
        return CloudStorageGallerySelectionPolicy.reconcile(
            remainingSelectedFileIDs: remainingSelectedFileIDs,
            datasourceFileIDs: datasource.map(\.fileId)
        )
    }

    private func reloadCollectionRestoringRemainingSelection() {
        let reconciliation = currentSelectionReconciliation()
        remainingSelectedFileIDs = Set(reconciliation.orderedFileIDs)

        collectionView.reloadData()
        (collectionView.indexPathsForSelectedItems ?? []).forEach {
            collectionView.deselectItem(at: $0, animated: false)
        }
        reconciliation.indexPaths.forEach {
            collectionView.selectItem(at: $0, animated: false, scrollPosition: [])
        }
        collectionView.layoutIfNeeded()
        refreshVisibleSelectionAppearance()
        updateSelectionControls()
    }

    private func refreshVisibleSelectionAppearance() {
        let selectedIndexPaths = Set(collectionView.indexPathsForSelectedItems ?? [])
        collectionView.indexPathsForVisibleItems.forEach { indexPath in
            let isSelected = selectedIndexPaths.contains(indexPath)
            switch selectedType {
            case .image, .avatar:
                guard let cell = collectionView.cellForItem(at: indexPath) as? PhotosMediaCollectionCell else { return }
                if isSelected { cell.select() } else { cell.deselect() }
            case .video:
                guard let cell = collectionView.cellForItem(at: indexPath) as? VideosMediaCollectionCell else { return }
                if isSelected { cell.select() } else { cell.deselect() }
            case .audio:
                guard let cell = collectionView.cellForItem(at: indexPath) as? VoiceMediaCollectionCell else { return }
                if isSelected { cell.select() } else { cell.deselect() }
            default:
                guard let cell = collectionView.cellForItem(at: indexPath) as? FilesMediaCollectionCell else { return }
                if isSelected { cell.select() } else { cell.deselect() }
            }
        }
    }

    private func updateSelectionControls() {
        guard collectionView.isEditing else { return }
        navigationItem.title = "\(remainingSelectedFileIDs.count) \(selectedType)s selected"
        deleteSelectedFilesButton?.isEnabled = !isDeletingSelectedFiles && remainingSelectedFileIDs.isNotEmpty
    }

    private func presentDeletionError() {
        let alert = UIAlertController(
            title: "Couldn't delete files",
            message: "Cloud Storage was not changed completely. Check your connection and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @objc func longPressGesture(_ gestureRecognizer: UILongPressGestureRecognizer) {
        guard gestureRecognizer.state == .began,
              !collectionView.isEditing else {
            return
        }
        let touchPoint = gestureRecognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: touchPoint),
              datasource.indices.contains(indexPath.item),
              datasource[indexPath.item].kind != .undefined,
              let fileID = datasource[indexPath.item].fileId else { return }
        impactFeedbackGenerator.impactOccurred()
        impactFeedbackGenerator.prepare()
        remainingSelectedFileIDs = [fileID]
        cancelSelectButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelSelectButtonTapped))
        deleteSelectedFilesButton = UIBarButtonItem(image: imageLiteral( "trash-outline"), style: .plain, target: self, action: #selector(deleteSelectedFilesButtonTapped))
        navigationItem.hidesBackButton = true
        navigationItem.setRightBarButton(deleteSelectedFilesButton, animated: true)
        navigationItem.setLeftBarButton(cancelSelectButton, animated: true)
        setEditing(true, animated: true)
        collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
        updateSelectionControls()
        return
    }
    
    let collectionView: UICollectionView = {
        let collectionViewflowLayout = UICollectionViewFlowLayout()
        collectionViewflowLayout.sectionInset = CloudStorageCategoryLayoutPolicy.sectionInsets
        let view = UICollectionView(frame: .zero, collectionViewLayout: collectionViewflowLayout)
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
        capturedGalleryIdentity = AccountGalleryConfiguration(owner: owner).currentGalleryIdentity
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudStorageGalleryDidChange(_:)),
            name: .cloudStorageGalleryDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .cloudStorageGalleryDidChange, object: nil)
    }

    private func gallerySelectionIsCurrent() -> Bool {
        return capturedGalleryIdentity == AccountGalleryConfiguration(owner: owner).currentGalleryIdentity
    }

    @objc private func cloudStorageGalleryDidChange(_ notification: Notification) {
        guard notification.userInfo?["jid"] as? String == owner else { return }
        items.removeAll()
        datasource.removeAll()
        collectionView.reloadData()
        navigationController?.popViewController(animated: true)
    }

    private func loadFiles() {
        loadError = nil
        items.removeAll()
        datasource.removeAll()
        collectionView.reloadData()
        showLoadingIndicator()

        guard let account = AccountManager.shared.find(for: owner) else {
            finishLoading(.failure(.unavailable))
            return
        }

        account.action { [weak self] user, _ in
            guard let self else { return }
            CloudStoragePagedLoader().loadAll(fetchPage: { page, completion in
                if self.selectedType == .avatar {
                    user.cloudStorage.getAvatarsPage(page: page, completion: completion)
                } else {
                    user.cloudStorage.getFilesPage(type: self.selectedType, page: page, completion: completion)
                }
            }, completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.finishLoading(result)
                }
            })
        }
    }

    private func showLoadingIndicator() {
        spinner.startAnimating()
        if spinner.superview == nil {
            view.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
    }

    private func finishLoading(_ result: Result<[NSDictionary], CloudStorageListLoadError>) {
        spinner.stopAnimating()
        spinner.removeFromSuperview()
        guard gallerySelectionIsCurrent() else { return }

        switch result {
        case .success(let items):
            self.items = items
            loadError = nil
        case .failure(let error):
            items.removeAll()
            loadError = error
        }
        configureCollections()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configureCollections() {
        datasource = items.compactMap {
            CloudStorageItemPresentation.make(from: $0, preferredType: selectedType)
        }
        datasource.sort { ($0.dateFormatted ?? .distantPast) > ($1.dateFormatted ?? .distantPast) }
        if datasource.isEmpty {
            datasource = [Datasource(kind: .undefined)]
        }

        switch selectedType {
        case .image:
            navigationItem.title = "Images"
        case .video:
            navigationItem.title = "Videos"
        case .audio:
            navigationItem.title = "Voice messages"
        case .avatar:
            navigationItem.title = "Avatars"
        default:
            navigationItem.title = "Files"
        }

        optionButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(optionButtonTapped)
        )
        optionButton?.isEnabled = loadError == nil && datasource.first?.kind != .undefined
        navigationItem.setRightBarButton(optionButton, animated: false)
        collectionView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(collectionView)
        collectionView.fillSuperview()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.allowsMultipleSelection = true
        collectionView.accessibilityIdentifier = "cloudStorage.category.list"
        infoVCDelegate = self
        loadFiles()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if CommonConfigManager.shared.config.use_large_title {
            self.navigationItem.largeTitleDisplayMode = .automatic
        } else {
            self.navigationItem.largeTitleDisplayMode = .never
        }
        self.navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        impactFeedbackGenerator.prepare()
        
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        if !editing {
            remainingSelectedFileIDs.removeAll()
            (collectionView.indexPathsForSelectedItems ?? []).forEach {
                collectionView.deselectItem(at: $0, animated: false)
            }
        }
        collectionView.isEditing = editing
        collectionView.reloadData()
        updateSelectionControls()
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
            if loadError != nil {
                cell.label.text = "Couldn't load Cloud Storage. Tap to retry."
                cell.accessibilityIdentifier = "cloudStorage.category.retry"
            } else if selectedType == .audio {
                cell.label.text = "No voice messages"
            } else {
                cell.label.text = "No \(selectedType.rawValue)s"
            }
            return cell
        }
        switch selectedType {
        case .image, .avatar:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotosMediaCollectionCell.cellName, for: indexPath) as! PhotosMediaCollectionCell
            guard let uri = item.uri else { return cell }
            cell.setup(photoUrls: (thumb: item.thumbnail, url: uri))
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
                if cell.contentView.gestureRecognizers?.count ?? 0 <= 1 {
                    cell.contentView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressGesture(_:))))
                }
                cell.editModeDisabled()
            }
            return cell
        case .audio:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VoiceMediaCollectionCell.cellName, for: indexPath) as! VoiceMediaCollectionCell
            let meters = item.meters?
                .split(separator: " ")
                .compactMap { Float($0) }
            let renderedMeters = (meters?.isEmpty == false ? meters : nil) ?? [0.0, 0.0]
            cell.audioView.configure(
                .paused,
                meters: renderedMeters,
                loading: false,
                duration: item.audioDuration ?? "",
                senderName: item.fileName ?? "Audio message",
                date: item.date ?? "",
                send_time: item.time ?? "",
                sizeInBytes: item.size ?? "0 KiB"
            )
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
            cell.setup(mimeType: item.mimeType ?? "file", sender: item.senderName ?? "", date: item.date ?? "", time: item.time ?? "", sizeInBytes: item.size ?? "0 KiB", filename: item.fileName ?? "File")
            
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
        if datasource[indexPath.item].kind == .undefined {
            return CGSize(
                width: CloudStorageCategoryLayoutPolicy.listItemWidth(
                    containerWidth: collectionView.bounds.width
                ),
                height: CloudStorageCategoryLayoutPolicy.listItemHeight
            )
        }
        switch selectedType {
        case .image, .video, .avatar:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = CloudStorageCategoryLayoutPolicy.spacing
            layout.minimumInteritemSpacing = CloudStorageCategoryLayoutPolicy.spacing
            let width = CloudStorageCategoryLayoutPolicy.gridItemWidth(
                containerWidth: collectionView.bounds.width
            )
            return CGSize(square: width)
            
        default:
            let layout = collectionViewLayout as! UICollectionViewFlowLayout
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            return CGSize(
                width: CloudStorageCategoryLayoutPolicy.listItemWidth(
                    containerWidth: collectionView.bounds.width
                ),
                height: CloudStorageCategoryLayoutPolicy.listItemHeight
            )
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard datasource.indices.contains(indexPath.item) else { return }
        if datasource[indexPath.item].kind == .undefined {
            collectionView.deselectItem(at: indexPath, animated: true)
            if loadError != nil {
                loadFiles()
            }
            return
        }
        if collectionView.isEditing {
            guard let fileID = datasource[indexPath.item].fileId else {
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            remainingSelectedFileIDs.insert(fileID)
            updateSelectionControls()
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
                if indexPath.item > 0 {
                    let previous = IndexPath(item: indexPath.item - 1, section: indexPath.section)
                    (collectionView.cellForItem(at: previous) as? FilesMediaCollectionCell)?.separatorLine.isHidden = true
                }
                return
            }
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        switch selectedType {
        case .image, .avatar:
            let imageUrls: [URL] = datasource.compactMap { $0.uri.flatMap(URL.init(string:)) }
            let senders = datasource.map { $0.senderName ?? "" }
            let dates = datasource.map { $0.date ?? "" }
            let times = datasource.map { $0.time ?? "" }
            let messageIds = datasource.map { $0.messageId ?? "" }
            
            self.infoVCDelegate?.presentPhotoGallery(urls: imageUrls, senders: senders, dates: dates, times: times, messageIds: messageIds, page: indexPath.item)
        default:
            guard let rawURL = datasource[indexPath.item].uri,
                  let url = URL(string: rawURL) else { return }
            infoVCDelegate?.presentYesNoPresenter(with: url)
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing,
           datasource.indices.contains(indexPath.item),
           let fileID = datasource[indexPath.item].fileId {
            remainingSelectedFileIDs.remove(fileID)
        }
        updateSelectionControls()
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
            if indexPath.item > 0 {
                let previous = IndexPath(item: indexPath.item - 1, section: indexPath.section)
                (collectionView.cellForItem(at: previous) as? FilesMediaCollectionCell)?.separatorLine.isHidden = false
            }
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
        if #available(iOS 26, *) {
            return 52
        } else {
            return 44
        }
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        dismiss(animated: false)
        remainingSelectedFileIDs.removeAll()
        cancelSelectButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancelSelectButtonTapped))
        deleteSelectedFilesButton = UIBarButtonItem(image: imageLiteral( "trash-outline"), style: .plain, target: self, action: #selector(deleteSelectedFilesButtonTapped))
        deleteSelectedFilesButton?.isEnabled = false
        navigationItem.hidesBackButton = true
        navigationItem.setRightBarButton(deleteSelectedFilesButton, animated: true)
        navigationItem.setLeftBarButton(cancelSelectButton, animated: true)
        setEditing(true, animated: true)
        updateSelectionControls()
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
        guard urls.indices.contains(page) else { return }
        let gallery = CloudPhotoGallery(urls: urls, from: urls[page])
        gallery.senders = normalizedMetadata(senders, count: urls.count)
        gallery.dates = normalizedMetadata(dates, count: urls.count)
        gallery.times = normalizedMetadata(times, count: urls.count)
        gallery.messageIds = normalizedMetadata(messageIds, count: urls.count)
        gallery.setPage(page: page)
        gallery.setupDelegate(photoGalleryDelegate: self)

        let navigationViewController = UINavigationController(rootViewController: gallery)
        navigationViewController.modalPresentationStyle = .overFullScreen
        present(navigationViewController, animated: true)
    }

    private func normalizedMetadata(_ values: [String], count: Int) -> [String] {
        if values.count >= count {
            return Array(values.prefix(count))
        }
        return values + Array(repeating: "", count: count - values.count)
    }
    
    func scrollToMediaGallery() {
    }
}
