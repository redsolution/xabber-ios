//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import UIKit
import SwiftUI
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff

class InfoScreenFooterView: UIView {
    struct Datasource: DiffAware {
        var diffId: String {
            get {
                return [messageId].prp()
            }
        }
        
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
        let kind: Kind
        let messageId: String
        let uri: String //Image url at dev.xabber.org
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
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
            return a.primary == b.primary
                && a.messageId == b.messageId
                && a.uri == b.uri
        }
    }
    
    enum Kind: String {
        case images = "Images"
        case videos = "Videos"
        case files = "Files"
        case voice = "Voice"
    }
    
    var selectedKind: Kind = .images
    var previousSelectedCellIndex: IndexPath?
    var selectedCell: VoiceMediaCollectionCell?
    
    public var canUpdateDataset = true
    var isFirstTimeOpened: Bool = true
    var needsCollectionUpdate: Bool = false
    
    public var conversationType: ClientSynchronizationManager.ConversationType = .regular
    
    static let numberOfCells: CGFloat = 3
    static let cellSpacing: CGFloat = 8
    static let scrollViewHeight: CGFloat = 45
    
    var jid: String = ""
    var owner: String = ""
    
    var mediaButtonsDelegate: InfoScreenFooterButtonDelegate? = nil
    var chatsDelegate: TappedPhotoInMediaGalleryDelegate? = nil
    var infoVCDelegate: InfoVCDelegate? = nil
    
    var isGroupChat: Bool?
    
    internal var bag: DisposeBag = DisposeBag()
    internal var chatsBag: DisposeBag = DisposeBag()
    var timer: Timer?
    
    private let queue: DispatchQueue = DispatchQueue(
        label: "com.xabber.gallery.update_task",
        qos: DispatchQoS.utility,
        attributes: [],
        autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency.workItem,
        target: nil)
    
    var datasource: [Datasource] = []
    
    //MARK: - Views
    let scrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .white
        view.showsHorizontalScrollIndicator = false
        
        return view
    }()
    
    let graySeparatorLine: UIView = {
        let view = UIView()
        view.backgroundColor = .lightGray
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    let mediaCollectionView: UICollectionView = {
        let collection = UICollectionView(frame: CGRect.zero, collectionViewLayout: UICollectionViewLayout.init())
        collection.backgroundColor = .white
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.allowsSelection = true
        collection.allowsMultipleSelection = false
        collection.alwaysBounceVertical = true
        collection.scrollsToTop = true
        collection.register(PhotosMediaCollectionCell.self,
                           forCellWithReuseIdentifier: PhotosMediaCollectionCell.cellName)
        collection.register(VideosMediaCollectionCell.self, forCellWithReuseIdentifier: VideosMediaCollectionCell.cellName)
        collection.register(FilesMediaCollectionCell.self, forCellWithReuseIdentifier: FilesMediaCollectionCell.cellName)
        collection.register(VoiceMediaCollectionCell.self, forCellWithReuseIdentifier: VoiceMediaCollectionCell.cellName)
        collection.register(NoFilesMediaCollectionCell.self, forCellWithReuseIdentifier: NoFilesMediaCollectionCell.cellName)

        return collection
    }()
    
    var collectionFlowLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = InfoScreenFooterView.cellSpacing
        layout.minimumInteritemSpacing = InfoScreenFooterView.cellSpacing
        
        return layout
    }()
    
    var mediaButtonsStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 0, bottom: 0, left: 24, right: 24)

        return stack
    }()
    
    let imagesButton: MediaKindButton = {
        let button = MediaKindButton(title: Kind.images.rawValue.localizeString(id: "images", arguments: []))
        
        button.setTitleColor(.systemGray, for: .normal)
        
        return button
    }()
    
    let videosButton: MediaKindButton = {
        let button = MediaKindButton(title: Kind.videos.rawValue.localizeString(id: "videos", arguments: []))
        
        button.setTitleColor(.systemGray, for: .normal)
        
        return button
    }()
    
    let filesButton: MediaKindButton = {
        let button = MediaKindButton(title: Kind.files.rawValue.localizeString(id: "files", arguments: []))
        
        button.setTitleColor(.systemGray, for: .normal)
        
        return button
    }()
    
    let voiceButton: MediaKindButton = {
        let button = MediaKindButton(title: Kind.voice.rawValue.localizeString(id: "voice", arguments: []))
        
        button.setTitleColor(.systemGray, for: .normal)
        
        return button
    }()
    
    var buttons: [UIButton] = []
    
    
    //MARK: - Inits
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
        deselectAllButtons()
        activateConstraints()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.contentSize.width = bounds.width
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    //MARK: - Buttons
    @objc
    private func imagesButtonPressed() {
        self.mediaButtonsDelegate?.onImagesButtonPressed()
        deselectAllButtons()
        imagesButton.isSelected = true
        selectedKind = .images
        
        needsCollectionUpdate = true
        getReferences()
        setCollectionLayout()
        mediaCollectionView.scrollToItem(at: IndexPath.init(item: 0, section: 0), at: [], animated: true)
        
        infoVCDelegate?.scrollToMediaGallery()
        
//        archiveRequest(filter: .image)
    }
    
    @objc
    private func videosButtonPressed() {
        self.mediaButtonsDelegate?.onVideosButtonPressed()
        deselectAllButtons()
        videosButton.isSelected = true
        selectedKind = .videos
        
        needsCollectionUpdate = true
        getReferences()
        setCollectionLayout()
        mediaCollectionView.scrollToItem(at: IndexPath.init(item: 0, section: 0), at: [], animated: true)
        
        infoVCDelegate?.scrollToMediaGallery()
        
//        archiveRequest(filter: .video)
    }
    
    @objc
    private func filesButtonPressed() {
        self.mediaButtonsDelegate?.onFilesButtonPressed()
        deselectAllButtons()
        filesButton.isSelected = true
        selectedKind = .files
        
        needsCollectionUpdate = true
        getReferences()
        setCollectionLayout()
        mediaCollectionView.scrollToItem(at: IndexPath.init(item: 0, section: 0), at: [], animated: true)
        
        infoVCDelegate?.scrollToMediaGallery()
        
//        archiveRequest(filter: .files)
    }
    
    @objc
    private func voiceButtonPressed() {
        self.mediaButtonsDelegate?.onVoiceButtonPressed()
        deselectAllButtons()
        voiceButton.isSelected = true
        selectedKind = .voice
        
        needsCollectionUpdate = true
        getReferences()
        setCollectionLayout()
        mediaCollectionView.scrollToItem(at: IndexPath.init(item: 0, section: 0), at: [], animated: true)

        infoVCDelegate?.scrollToMediaGallery()
        
//        archiveRequest(filter: .voice)
    }
    
    //MARK: - Trouble with getting current x of the button: if it's scrolled in scrollView, coords remain still
    func calculateScrollViewContentOffset(for button: UIButton) {
        let diff = center.x - (button.frame.origin.x + button.frame.midX - button.frame.minX)
        let scrollMaxX = scrollView.contentSize.width - frame.width
        // Button is in the left half of the view
        if diff > 0 {
            if scrollView.bounds.origin.x > (frame.width / 2) {
                scrollView.bounds.origin.x -= diff
            }
        }
        
        // Button is in the right half of the view
        if diff < 0 {
            if (scrollMaxX - scrollView.bounds.origin.x) < abs(scrollMaxX - frame.width / 2) {
                scrollView.bounds.origin.x = scrollMaxX
            } else {
                scrollView.bounds.origin.x += abs(diff)
            }
        }
    }
    
    internal func setup() {
        self.backgroundColor = .white
        getReferences()
        
        self.addSubview(scrollView)
        
        buttons = [imagesButton, videosButton, filesButton, voiceButton]
        for button in buttons {
            mediaButtonsStackView.addArrangedSubview(button)
        }
        scrollView.addSubview(mediaButtonsStackView)
        scrollView.contentSize.width = frame.width
        addSubview(graySeparatorLine)
        
        setCollectionLayout()
        addSubview(mediaCollectionView)
        
        mediaCollectionView.delegate = self
        mediaCollectionView.dataSource = self
        mediaCollectionView.collectionViewLayout = collectionFlowLayout
        
        imagesButton.addTarget(self, action: #selector(imagesButtonPressed), for: .touchUpInside)
        videosButton.addTarget(self, action: #selector(videosButtonPressed), for: .touchUpInside)
        filesButton.addTarget(self, action: #selector(filesButtonPressed), for: .touchUpInside)
        voiceButton.addTarget(self, action: #selector(voiceButtonPressed), for: .touchUpInside)

        needsCollectionUpdate = true
    }
    
    func setCollectionLayout() {
        switch selectedKind {
        case .voice, .files:
            collectionFlowLayout.minimumLineSpacing = 0
            collectionFlowLayout.minimumInteritemSpacing = 0
            mediaCollectionView.contentInset = UIEdgeInsets(top: 0,
                                                            bottom: 0,
                                                            left: InfoScreenFooterView.cellSpacing,
                                                            right: InfoScreenFooterView.cellSpacing)
        default:
            collectionFlowLayout.minimumLineSpacing = InfoScreenFooterView.cellSpacing
            collectionFlowLayout.minimumInteritemSpacing = InfoScreenFooterView.cellSpacing
            mediaCollectionView.contentInset = UIEdgeInsets(top: InfoScreenFooterView.cellSpacing,
                                                        bottom: InfoScreenFooterView.cellSpacing,
                                                        left: InfoScreenFooterView.cellSpacing,
                                                        right: InfoScreenFooterView.cellSpacing)
        }
        mediaCollectionView.reloadData()
    }

    internal func activateConstraints() {
        NSLayoutConstraint.activate([
            scrollView.leftAnchor.constraint(equalTo: leftAnchor),
            scrollView.rightAnchor.constraint(equalTo: rightAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: InfoScreenFooterView.scrollViewHeight),
            
            mediaButtonsStackView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            mediaButtonsStackView.widthAnchor.constraint(equalTo: self.widthAnchor),
            
            graySeparatorLine.leftAnchor.constraint(equalTo: leftAnchor),
            graySeparatorLine.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            graySeparatorLine.rightAnchor.constraint(equalTo: rightAnchor),
            graySeparatorLine.heightAnchor.constraint(equalToConstant: 0.3),
            
            mediaCollectionView.topAnchor.constraint(equalTo: graySeparatorLine.bottomAnchor),
            mediaCollectionView.leftAnchor.constraint(equalTo: leftAnchor),
            mediaCollectionView.rightAnchor.constraint(equalTo: rightAnchor),
            mediaCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44),
        ])
    }
    
    internal func deselectAllButtons() {
        for button in buttons {
            button.isSelected = false
        }
    }
    
    
    internal func getReferences() {
        self.bag = DisposeBag()
        
        do {
            let realm = try WRealm.safe()
            
            let predicate = makePredicate()
            let collection = realm
                .objects(MessageReferenceStorageItem.self)
                .filter(predicate)
                .sorted(byKeyPath: "sentDate", ascending: false)
            needsCollectionUpdate = true
            self.canUpdateDataset = true
            self.runSourceUpdateTask()
            
            Observable
                .collection(from: collection)
                .debounce(.milliseconds(1000), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.runSourceUpdateTask()
                    self.archiveRequestWithFilter()
                }
                .disposed(by: bag)
            
        } catch {
            DDLogDebug("InfoScreenFooterView: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func makePredicate() -> NSPredicate {
        let predicate: NSPredicate
        
        switch selectedKind {
        case .images:
            if self.jid != "" && self.owner == "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "image")
            } else if self.jid == "" && self.owner != "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, MessageReferenceStorageItem.Kind.media.rawValue, "image")
            } else {
                predicate = NSPredicate(format: "jid == %@ AND owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.jid, self.owner, MessageReferenceStorageItem.Kind.media.rawValue, "image")
            }
        case .videos:
            if self.jid != "" && self.owner == "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.jid, MessageReferenceStorageItem.Kind.media.rawValue, "video")
            } else if self.jid == "" && self.owner != "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.owner, MessageReferenceStorageItem.Kind.media.rawValue, "video")
            } else {
                predicate = NSPredicate(format: "jid == %@ AND owner == %@ AND kind_ == %@ AND mimeType == %@ AND hasError == false", self.jid, self.owner, MessageReferenceStorageItem.Kind.media.rawValue, "video")
            }
        case .files:
//            let mimeTypes: [String] = mimeIcon.compactMap ({
//                item -> String? in
//                if item.value == .document ||
//                   item.value == .pdf ||
//                   item.value == .table ||
//                   item.value == .presentation ||
//                   item.value == .archive ||
//                   item.value == .audio ||
//                   item.value == .file {
//                     let start = item.key.lastIndex(of: "/") ?? item.key.startIndex
//                     let mimeType = String(item.key[start..<item.key.endIndex]).replacingOccurrences(of: "/", with: "")
//
//                     return mimeType
//                }
//                return nil
//            })
            let mimeTypes: [String] = ["document", "pdf", "table", "presentation", "archive", "audio", "file"]
            if self.jid != "" && self.owner == "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType IN %@ AND hasError == false", self.jid, MessageReferenceStorageItem.Kind.media.rawValue, mimeTypes)
            } else if self.jid == "" && self.owner != "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND mimeType IN %@ AND hasError == false", self.owner, MessageReferenceStorageItem.Kind.media.rawValue, mimeTypes)
            } else {
                predicate = NSPredicate(format: "jid == %@ AND owner == %@ AND kind_ == %@ AND mimeType IN %@ AND hasError == false", self.jid, self.owner, MessageReferenceStorageItem.Kind.media.rawValue, mimeTypes)
            }
        case .voice:
            if self.jid != "" && self.owner == "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND hasError == false", self.jid, MessageReferenceStorageItem.Kind.voice.rawValue)
            } else if self.jid == "" && self.owner != "" {
                predicate = NSPredicate(format: "owner == %@ AND kind_ == %@ AND hasError == false", self.owner, MessageReferenceStorageItem.Kind.voice.rawValue)
            } else {
                predicate = NSPredicate(format: "jid == %@ AND owner == %@ AND kind_ == %@ AND hasError == false", self.jid, self.owner, MessageReferenceStorageItem.Kind.voice.rawValue)
            }
        }
        return predicate
    }
    
    func archiveRequestWithFilter() {
//        switch self.selectedKind {
//        case .images:
//            self.initialArchiveRequest(filter: .image)
//        case .videos:
//            self.initialArchiveRequest(filter: .video)
//        case .files:
//            self.initialArchiveRequest(filter: .files)
//        case .voice:
//            self.initialArchiveRequest(filter: .voice)
//        }
    }
    
    
    func runSourceUpdateTask() {
        preUpdateTask()
        postUpdateTask()
    }
    
    private func preUpdateTask() {
        if !canUpdateDataset { return }
//        self.queue.sync {
            canUpdateDataset = false
            let newDatasource = prepareDatasource()
            let changes = diff(old: self.datasource, new: newDatasource)
            let indexPaths = self.convertChangeset(changes: changes)
            if indexPaths.inserts.isEmpty && indexPaths.deletes.isEmpty && indexPaths.moves.isEmpty && indexPaths.replaces.isEmpty {
                return
            }
            if needsCollectionUpdate {
                needsCollectionUpdate = false
                self.datasource = newDatasource
                mediaCollectionView.reloadData()
                return
            }
            self.apply(changes: indexPaths) {
                self.datasource = newDatasource
            }
//        }
    }
    
    internal func prepareDatasource() -> [Datasource] {
        do {
            let realm = try WRealm.safe()
            
            let predicate = makePredicate()
            let collection = realm
                .objects(MessageReferenceStorageItem.self)
                .filter(predicate)
                .sorted(byKeyPath: "sentDate", ascending: false)
            
            let newDatasource: [Datasource] = collection.toArray().compactMap { item in //results.toArray()
//                do {
//                    try realm.write {
//                        item.isMissed = false
//                    }
//                } catch {
//                    
//                }
                if item.isMissed == true {
                    return nil
                }
                if let uri = item.metadata?["uri"] as? String {
                    var voiceModel: MessageReferenceStorageItem.Model?
                    if item.kind_ == "voice" {
                        voiceModel = item.loadModel()
                    }
                    let senderData = PhotoGallery.getSenderName(messageId: item.messageId)
                    
                    var kind: InfoScreenFooterView.Datasource.Kind = .image
                    
                    switch selectedKind {
                        case .images: kind = .image
                        case .videos: kind = .video
                        case .files: kind = .file
                        case .voice: kind = .voice
                    }
                    
                    if item.videoPreviewKey == nil {
                        MessageReferenceStorageItem.prepareVideo(message: item.primary)
                    }

                    return Datasource(
                        primary: item.primary,
                        jid: item.jid,
                        owner: item.owner,
                        kind: kind,
                        messageId: item.messageId,
                        uri: uri,
                        thumbnail: item.metadata?["thumbnail"] as? String,
                        videoPreviewKey: item.videoPreviewKey,
                        videoOrientation: item.videoOrientation,
                        voiceModel: (voiceModel != nil) ? voiceModel : nil,
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
                return nil
            }
            return newDatasource
        } catch {
            DDLogDebug("InfoScreenFooterView: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    private func postUpdateTask() {
        
    }
    

    
    internal final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let inserts =  changes.compactMap { return $0.insert?.index }.compactMap({ return IndexPath(row:$0, section: 0)})
        let deletes =  changes.compactMap { return $0.delete?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        let replaces = changes.compactMap { return $0.replace?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: $0.fromIndex, section: 0),
            to: IndexPath(item: $0.toIndex, section: 0)
          )
        })
        
        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    internal final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.canUpdateDataset = true
            return
        }
        
        self.mediaCollectionView.performBatchUpdates({
            prepare()
            if !changes.deletes.isEmpty {
                self.mediaCollectionView.deleteItems(at: changes.deletes)
            }
            
            if !changes.inserts.isEmpty {
                self.mediaCollectionView.insertItems(at: changes.inserts)
            }
            
            if !changes.replaces.isEmpty {
                self.mediaCollectionView.reloadItems(at: changes.replaces)
            }
        
            if changes.moves.isNotEmpty {
                changes.moves.forEach {
                    (from, to) in
                    self.mediaCollectionView.moveItem(at: from, to: to)
                }
            }
        }, completion: {
            result in
            self.canUpdateDataset = true
//            if changes.replaces.isEmpty { return }
//            UIView.performWithoutAnimation {
//                self.mediaCollectionView.reloadItems(at: changes.replaces)
//            }
        })
    }
    
    
    func setupTimer() {
        if timer == nil {
            timer = Timer.scheduledTimer(timeInterval: 0.5,
                                         target: self,
                                         selector: #selector(timerUpdateTask),
                                         userInfo: nil,
                                         repeats: true)
        }
    }
    
    @objc
    func timerUpdateTask() {
        guard let cell = selectedCell else { return }
        cell.timerUpdateTask()
    }
    
    func resetTimer() {
        timer = nil
    }
}
