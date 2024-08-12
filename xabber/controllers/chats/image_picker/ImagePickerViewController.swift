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

import Foundation
import UIKit
import AVFoundation
import Photos
import MaterialComponents.MDCPalettes
import MobileCoreServices
import Kingfisher
import AudioToolbox
import CocoaLumberjack
import AVKit

class ImagePickerViewController: UIViewController {
    
    public var jid: String = ""
    public var owner: String = ""
    public var forwardedMessages: [String] = []
    
    var media: [MessageReferenceStorageItem] = []
    
    var moments: PHFetchResult<PHAsset>?
    
    var delegate: ImagePickerViewDelegate?
    
    public var conversationType: ClientSynchronizationManager.ConversationType = .regular
    
    var dimmed: UIView = {
        let view = UIView()
        return view
    }()
    
    var baseView: UIView = {
        let view = UIView()
        return view
    }()
    
    var img: UIImageView = {
        return UIImageView()
    }()
    
    var collectionLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        return layout
    }()
    
    var collectionView: UICollectionView?
    
    let collectionViewImageSize: CGSize = CGSize(square: 80)
    let collectionViewImageSizeHD: CGSize = CGSize(square: 240)
    
    var separator: UIView = {
        let view = UIView()
        return view
    }()
    
    var itemsSelected: Set<Int> = Set<Int>()
    
//    var otherItems: Set<ImagePickerSelectedItem> = Set<ImagePickerSelectedItem>()
    
    var sendDismissButton: UIButton?
    var sendLabel: UILabel?
    
    internal func setupCaptureSession() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            let cameraPickerVC = UIImagePickerController()
            cameraPickerVC.delegate = self
            cameraPickerVC.sourceType = .camera
            cameraPickerVC.mediaTypes = UIImagePickerController.availableMediaTypes(for: .camera) ?? []
            self.present(cameraPickerVC, animated: true, completion: nil)
        } else {
            DDLogDebug("camera denied")
        }
    }
    
    
    
    internal func updateSendButton() {
        if self.itemsSelected.count > 0 {
//            enable send button
            self.sendLabel!.text = "Send (\(self.itemsSelected.count))"
            self.sendLabel!.isHidden = false
            self.configiureSend(self.sendDismissButton!)
        } else {
//            disable send button
            self.sendLabel!.isHidden = true
            self.configureDissmiss(self.sendDismissButton!)
        }
    }
    
    @objc
    internal func openCamera() {
        self.setupCaptureSession()
    }
    
    @objc
    internal func openGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            let galleryPickerVC = UIImagePickerController()
            galleryPickerVC.delegate = self
            galleryPickerVC.sourceType = .photoLibrary
            galleryPickerVC.videoQuality = .typeMedium
            galleryPickerVC.mediaTypes = UIImagePickerController.availableMediaTypes(for: .photoLibrary) ?? []
            self.present(galleryPickerVC, animated: true, completion: nil)
        }
    }
    
    @objc
    internal func openDocuments() {
        let documentVC = UIDocumentPickerViewController(documentTypes: [String(kUTTypeItem)], in: .import)
        if #available(iOS 11.0, *) {
            documentVC.allowsMultipleSelection = true
        }
        documentVC.delegate = self
        self.present(documentVC, animated: true, completion: nil)
    }
    
    @objc
    internal func dismissModal(_ force: Bool = false) {
        self.delegate?.onDismissPicker()
        UIView.animate(withDuration: 0.1, animations: {
            self.baseView.frame = CGRect(x: 0, y: self.view.frame.height, width: self.view.frame.width, height: 190)
            self.dimmed.alpha = 0.0
            self.blurredEffectView.frame = self.baseView.bounds
        }) { _ in
            self.dismiss(animated: false, completion: nil)
        }
    }
    
    @objc
    internal func send() {
//        DispatchQueue.global(qos: .default).async {
            
            
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                if self.itemsSelected.isEmpty && self.media.isEmpty { return }
                self.itemsSelected.forEach {
                    index in
                    let asset = self.moments!.object(at: index)
                    
                    let options: PHImageRequestOptions = PHImageRequestOptions()
                    options.resizeMode = .exact
                    options.isNetworkAccessAllowed = true
                    options.deliveryMode = .highQualityFormat
                    options.isSynchronous = true
                    PHImageManager.default().requestImage(for: asset,
                                                          targetSize: CGSize(square: 1024),
                                                          contentMode: PHImageContentMode.aspectFit,
                                                          options: options,
                                                          resultHandler: { (image, info) in
                        if let url = URL(string: [UUID().uuidString, "jpg"].joined(separator: ".")),
                            let image = image {
                            self.media.append(self.addImageBy(url, image: image))
                        }
                    })
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    user.messages.sendMediaMessage(self.media, to: self.jid, forwarded: self.forwardedMessages, conversationType: self.conversationType)
                    
                    self.delegate?.onSendMessage()
                }
                
            })
//        }
        self.dismissModal()
    }
    
    internal func getLastSavedImages() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 50
        self.moments = PHAsset.fetchAssets(with: .image, options: fetchOptions)
    }
    
    internal func pickerLabel(_ origin: CGPoint, itemWidth: CGFloat, configure: (UILabel)->Void) -> UILabel {
        let label = UILabel(frame: CGRect(origin: origin, size: CGSize(width: itemWidth, height: 16)))
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = MDCPalette.grey.tint700
        label.textAlignment = .center
        configure(label)
        return label
    }
    
    internal func pickerButton(_ origin: CGPoint, itemWidth: CGFloat, configure: (UIButton)->Void) -> UIButton {
        let padding = ( itemWidth - 56 ) / 2
        let newOrigin = CGPoint(x: origin.x + padding, y: origin.y)
        let button = UIButton(frame: CGRect(origin: newOrigin, size: CGSize(width: 56, height: 56)))
        configure(button)
        button.layer.borderWidth = 0.1
        button.layer.masksToBounds = true
        button.layer.borderColor = UIColor.black.cgColor
        button.layer.cornerRadius = button.frame.height/2
        button.clipsToBounds = true
        button.imageView?.contentMode = .scaleAspectFill
        button.tintColor = .white
        button.imageEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return button
    }
    
    internal func configureDissmiss(_ button: UIButton) {// -> UIButton {
        button.setImage(imageLiteral("chevron.down"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = .systemGray
        button.imageEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        button.addTarget(self, action: #selector(self.dismissModal), for: .touchUpInside)
    }
    
    internal func configiureSend(_ button: UIButton) {
        button.setImage(imageLiteral("xabber.paperplane.fill"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = .systemGreen
        button.imageEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 12)
        button.addTarget(self, action: #selector(self.send), for: .touchUpInside)
    }
    
    internal func refresh() {
        DispatchQueue.main.async {
            self.getLastSavedImages()
            self.collectionView?.reloadData()
        }
    }
    
    internal func hideCollectionView(reverse: Bool = false) {
        DispatchQueue.main.async {
            if (self.collectionView?.isHidden ?? false) != reverse { return }
            UIView.animate(withDuration: 0.33, animations: {
                self.baseView.frame = CGRect(x: 0,
                                             y: self.view.frame.height - (reverse ? 190 : 90),
                                             width: self.view.frame.width,
                                             height: (reverse ? 190 : 90))
                self.blurredEffectView.frame = self.baseView.bounds
                self.collectionView?.isHidden = !reverse
                self.separator.isHidden = !reverse
            })
        }
    }
    
    internal func configureDimmed() {
        dimmed.frame = self.view.bounds
        dimmed.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        
        let tapGesture = UITapGestureRecognizer(target: dimmed, action: nil)//, action: #selector(handleTapGesture))
        tapGesture.addTarget(self, action: #selector(dismissModal))
        tapGesture.delaysTouchesBegan = true
        
        dimmed.addGestureRecognizer(tapGesture)
        self.view.addSubview(dimmed)
    }
    
    internal func configureButtons() {
        let containerWidth = self.view.frame.width / 4
        
        baseView.addSubview(pickerButton(CGPoint(x: 0, y: 108), itemWidth: containerWidth) {
            $0.setImage(imageLiteral("camera.fill", dimension: 24), for: .normal)
            $0.backgroundColor = .systemRed
            $0.addTarget(self, action: #selector(self.openCamera), for: .touchUpInside)
        })
        
        baseView.addSubview(pickerLabel(CGPoint(x: 0, y: 166), itemWidth: containerWidth) {
            $0.text = "Camera".localizeString(id: "camera", arguments: [])
        })
        
        baseView.addSubview(pickerButton(CGPoint(x: containerWidth + 0, y: 108), itemWidth: containerWidth) {
            $0.setImage(imageLiteral("photo", dimension: 24), for: .normal)
            $0.backgroundColor = .systemPurple
            $0.addTarget(self, action: #selector(self.openGallery), for: .touchUpInside)
        })
        
        baseView.addSubview(pickerLabel(CGPoint(x: containerWidth, y: 166), itemWidth: containerWidth) {
            $0.text = "Gallery".localizeString(id: "gallery", arguments: [])
        })
        
        baseView.addSubview(pickerButton(CGPoint(x: containerWidth * 2 + 0, y: 108), itemWidth: containerWidth) {
            $0.setImage(imageLiteral("doc.fill", dimension: 24), for: .normal)
            $0.backgroundColor = .systemBlue
            $0.addTarget(self, action: #selector(self.openDocuments), for: .touchUpInside)
        })
        
        baseView.addSubview(pickerLabel(CGPoint(x: containerWidth * 2, y: 166), itemWidth: containerWidth) {
            $0.text = "Documents".localizeString(id: "documents", arguments: [])
        })
        
        self.sendDismissButton = pickerButton(CGPoint(x: containerWidth * 3 + 0, y: 108), itemWidth: containerWidth) {
            self.configureDissmiss($0)
        }
        self.sendLabel = pickerLabel(CGPoint(x: containerWidth * 3, y: 166), itemWidth: containerWidth) {
            $0.isHidden = true
        }
        
        baseView.addSubview(self.sendDismissButton!)
        baseView.addSubview(self.sendLabel!)
    }
    
    internal func configureCollectionView() {
        collectionLayout.itemSize = collectionViewImageSize
        collectionLayout.scrollDirection = .horizontal
        collectionLayout.minimumInteritemSpacing = 8
        collectionView = UICollectionView(frame: CGRect(x: 8, y: 8, width: self.baseView.frame.width - 16, height: 88), collectionViewLayout: collectionLayout)
        collectionView!.delegate = self
        collectionView!.dataSource = self
        collectionView!.backgroundColor = .clear
        collectionView!.contentMode = .left
        
        collectionView!.allowsSelection = true
        collectionView!.allowsMultipleSelection = true
        
        collectionView!.contentSize = CGSize(width: collectionViewImageSize.width * CGFloat(moments?.countOfAssets(with: .image) ?? 0), height: collectionViewImageSize.height + 12)
        collectionView!.register(ImagePickerCollectionViewCell.self, forCellWithReuseIdentifier: "imagePickerCell")
        baseView.addSubview(collectionView!)
    }
    
    internal func requestAccess() {
        switch PHPhotoLibrary.authorizationStatus() {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { (status) in
                switch status {
                case .restricted, .notDetermined, .denied:
                    self.hideCollectionView()
                case .authorized:
                    self.hideCollectionView(reverse: true)
                case .limited:
                    self.hideCollectionView(reverse: true)
                @unknown default:
                    self.hideCollectionView()
                }
                self.refresh()
            }
        case .limited:
            self.refresh()
        case .denied, .restricted:
            self.dismissModal()
        case .authorized:
            self.refresh()
        @unknown default:
            self.dismissModal()
        }
    }
    
    let blurredEffectView: UIVisualEffectView = {
        let blurEffect = UIBlurEffect(style: .systemMaterial)
        let blurredEffectView = UIVisualEffectView(effect: blurEffect)
        
        return blurredEffectView
    }()
    
    internal func configure() {
        
        getLastSavedImages()
        PHPhotoLibrary.shared().register(self)
        
        configureDimmed()
        let additionalInset: CGFloat
        if #available(iOS 11.0, *) {
            additionalInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0
        } else {
            additionalInset = 0
        }
        
        baseView.frame = CGRect(x: 0, y: self.view.frame.height, width: self.view.frame.width, height: 190 + additionalInset)
        blurredEffectView.frame = baseView.bounds
        baseView.addSubview(self.blurredEffectView)
        
        self.view.addSubview(baseView)
        
        separator.frame = CGRect(x: 16, y: 100, width: self.view.frame.width - 32, height: 1)
        separator.backgroundColor = MDCPalette.grey.tint200
        baseView.addSubview(separator)
        
        configureButtons()
        configureCollectionView()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let additionalInset: CGFloat
        if #available(iOS 11.0, *) {
            additionalInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0
        } else {
            additionalInset = 0
        }
        UIView.animate(withDuration: 0.18) {
            self.baseView.frame = CGRect(x: 0, y: self.view.frame.height - 190 - additionalInset, width: self.view.frame.width, height: 190 + additionalInset)
            self.blurredEffectView.frame = self.baseView.bounds
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
//        getAppTabBar()?.show()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}

extension ImagePickerViewController: UICollectionViewDelegateFlowLayout {
//    collectionview
}

extension ImagePickerViewController: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.getLastSavedImages()
            self.collectionView?.reloadData()
        }
    }
}

extension ImagePickerViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return moments?.countOfAssets(with: .image) ?? 0
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView
            .dequeueReusableCell(withReuseIdentifier: "imagePickerCell",
                                 for: indexPath) as? ImagePickerCollectionViewCell
            else {
                fatalError("cant dequeue cell with name: imagePickerCell")
            }
        cell.configure()
        cell.contentView.backgroundColor = .white
        let requestOption: PHImageRequestOptions = PHImageRequestOptions()
        requestOption.resizeMode = .exact
        requestOption.deliveryMode = .highQualityFormat
        
        let imageView = UIImageView(frame: cell.contentView.bounds)
        PHImageManager
            .default()
            .requestImage(
                for: moments!.object(at: indexPath.row),
                targetSize: collectionViewImageSizeHD,
                contentMode: .aspectFill,
                options: requestOption) {
                    (image, result) in
                    DispatchQueue.main.async {
                        imageView.image = image
                        imageView.contentMode = .scaleAspectFill
                    }
                }
        cell.contentView.addSubview(imageView)
        cell.updateSelection()
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return collectionViewImageSize
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) as? ImagePickerCollectionViewCell
        {
            cell.updateSelection()
            self .itemsSelected.insert(indexPath.row)
            self.updateSendButton()
        }
    }
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) as? ImagePickerCollectionViewCell{
            cell.updateSelection()
            self.itemsSelected.remove(indexPath.row)
            self.updateSendButton()
        }
    }
}

extension ImagePickerViewController: UIImagePickerControllerDelegate {
    
    internal func addImageDataBy(_ url: URL, data: Data, size: CGSize) -> MessageReferenceStorageItem {
        let item = MessageReferenceStorageItem()
        item.kind = .media
        item.owner = self.owner
        item.jid = self.jid
        item.conversationType = self.conversationType
        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
        item.temporaryData = data
        item.metadata = [
            "name": "Image".localizeString(id: "chat_message_image", arguments: []),
            "filename": url.lastPathComponent,
            "size": item.temporaryData?.count ?? 0,
            "media-type": MimeType(url: url).value,
            "uri": url.absoluteString,
            "width": size.width,
            "height": size.height,
        ]
        
        ImageCache.default.storeToDisk(data, forKey: url.absoluteString)
        item.primary = UUID().uuidString
        item.localFileUrl = item.temporaryData?.saveToTemporaryDir(name: url.lastPathComponent)
        return item
    }
    
    internal func addImageBy(_ url: URL, image: UIImage) -> MessageReferenceStorageItem {
        let item = MessageReferenceStorageItem()
        item.kind = .media
        item.owner = self.owner
        item.jid = self.jid
        item.conversationType = self.conversationType
        item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
        item.temporaryData = image.jpegData(compressionQuality: 0.9)
        item.metadata = [
            "name": "Image".localizeString(id: "chat_message_image", arguments: []),
            "filename": url.lastPathComponent,
            "size": item.temporaryData?.count ?? 0,
            "media-type": "image/jpeg",
            "uri": url.absoluteString,
            "width": image.size.width,
            "height": image.size.height,
        ]
        
        ImageCache.default.store(image, forKey: url.absoluteString)
        item.primary = UUID().uuidString
        item.localFileUrl = item.temporaryData?.saveToTemporaryDir(name: url.lastPathComponent)
        return item
    }
    
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        var url: URL? = nil
        if #available(iOS 11.0, *) {
            url = info[UIImagePickerController.InfoKey.imageURL] as? URL
        } else {
            url = info[UIImagePickerController.InfoKey.mediaURL] as? URL
        }
        if let imageRaw = (info[UIImagePickerController.InfoKey.editedImage] as? UIImage) ?? (info[UIImagePickerController.InfoKey.originalImage] as? UIImage) {
            if let imageOriginal = info[UIImagePickerController.InfoKey.originalImage] as? UIImage {
                if picker.sourceType == .camera {
                    UIImageWriteToSavedPhotosAlbum(imageOriginal, self, nil, nil)
                }
            }
            
            if let asset = info[UIImagePickerController.InfoKey.phAsset] as? PHAsset,
                asset.playbackStyle == .imageAnimated {
                print("ITS GIF")
                asset.getURL { url in
                    if let url = url,
                       let data = try? Data(contentsOf: url) {
                        print("asset data", data)
                        self.media.append(self.addImageDataBy(url, data: data, size: imageRaw.size))
                        picker.dismiss(animated: true) {
                            DispatchQueue.main.async {
                                self.send()
                                self.dismissModal()
                            }
                        }
                    }
                }
            } else {
                let image = imageRaw.fixOrientation().safeResize(to: 768)
                let imageUrl = url ?? URL(string: [UUID().uuidString, ".jpg"].joined(separator: "."))!
                media.append(addImageBy(imageUrl, image: image))
                picker.dismiss(animated: true) {
                    DispatchQueue.main.async {
                        self.send()
                        self.dismissModal()
                    }
                }
            }
        } else {
            url = info[UIImagePickerController.InfoKey.mediaURL] as? URL
            if let url = url {
                media.append(addMediaBy(url))
                picker.dismiss(animated: true) {
                    DispatchQueue.main.async {
                        self.send()
                        self.dismissModal()
                    }
                }
            }
        }
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.media.removeAll()
        self.refresh()
        picker.dismiss(animated: true, completion: nil)
    }
}

extension ImagePickerViewController: UINavigationControllerDelegate {
    
}

extension ImagePickerViewController: UIDocumentPickerDelegate {
    internal func addMediaBy(_ url: URL) -> MessageReferenceStorageItem {
        let item = MessageReferenceStorageItem()
        item.kind = .media
        item.temporaryData = try? Data(contentsOf: url)
        let mimeType = MimeIcon(MimeType(url: url).value).value
        item.mimeType = mimeType.rawValue
        item.owner = self.owner
        item.jid = self.jid
        item.conversationType = self.conversationType
        item.metadata = [
            "filename": url.lastPathComponent,
            "size": item.temporaryData?.count ?? 0,
            "media-type": MimeType(url: url).value,
            "uri": url.absoluteString
        ]
        
        item.primary = UUID().uuidString
        item.localFileUrl = item.temporaryData?.saveToTemporaryDir(name: url.lastPathComponent)
        
        switch mimeType {
        case .image:
            item.metadata?["name"] = "Image"
            if let data = item.temporaryData,
                let image = KFCrossPlatformImage(data: data) {
                item.metadata?["width"] = image.size.width.rounded()
                item.metadata?["height"] = image.size.height.rounded()
                ImageCache.default.store(image, forKey: url.absoluteString)
            }
        case .audio:
            item.metadata?["name"] = url.lastPathComponent
            item.metadata?["duration"] = try? AVAudioPlayer(contentsOf: url).duration
        case .video:
            item.metadata?["name"] = "Video"
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else { break }
            
            let transform = track.preferredTransform
            let size = track.naturalSize.applying(transform)

            let orientation = asset.videoOrientation().orientation.rawValue
            
            item.metadata?["width"] = abs(size.width)
            item.metadata?["height"] = abs(size.height)
            item.videoOrientation = orientation
            
            // add initialization of videoPreviewKey and videoDuration
            let url = item.metadata?["uri"] as! String
            let key = [jid, owner, url].prp()
            let result = item.extractFrameFromVideo(forKey: key)
            item.isDownloaded = true
            item.videoPreviewKey = key
            item.video_duration = result.video_duration ?? ""
        default:
            item.metadata?["name"] = url.lastPathComponent
        }
        
//        HTTPUploadsManager.storeData(item.temporaryData!, for: item.primary)
        return item
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        self.media.append(addMediaBy(url))
        controller.dismiss(animated: true) {
            DispatchQueue.main.async {
                self.send()
                self.dismissModal()
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.media.removeAll()
        self.refresh()
    }

    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        urls.forEach { self.media.append(addMediaBy($0)) }
        controller.dismiss(animated: true) {
            
        }
        DispatchQueue.main.async {
            self.send()
            self.dismissModal()
        }
    }
    
}

extension PHAsset {
    
    func getURL(completionHandler : @escaping ((_ responseURL : URL?) -> Void)){
        if self.mediaType == .image {
            let options: PHContentEditingInputRequestOptions = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = {(adjustmeta: PHAdjustmentData) -> Bool in
                return true
            }
            self.requestContentEditingInput(with: options, completionHandler: {(contentEditingInput: PHContentEditingInput?, info: [AnyHashable : Any]) -> Void in
                completionHandler(contentEditingInput!.fullSizeImageURL as URL?)
            })
        } else if self.mediaType == .video {
            let options: PHVideoRequestOptions = PHVideoRequestOptions()
            options.version = .original
            PHImageManager.default().requestAVAsset(forVideo: self, options: options, resultHandler: {(asset: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable : Any]?) -> Void in
                if let urlAsset = asset as? AVURLAsset {
                    let localVideoUrl: URL = urlAsset.url as URL
                    completionHandler(localVideoUrl)
                } else {
                    completionHandler(nil)
                }
            })
        }
    }
}
