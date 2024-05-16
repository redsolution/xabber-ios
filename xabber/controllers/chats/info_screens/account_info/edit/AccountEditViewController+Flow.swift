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
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift
import Kingfisher
import LetterAvatarKit
import AVFoundation

extension AccountEditViewController {
    
    internal func validate() {
        if !avatarChanged {
            var out: Bool = false
            originalStructure.forEach { (original) in
                vcardStructure.forEach({ (modified) in
                    if original.key == modified.key {
                        if original.value != modified.value {
                            out = true
                        }
                    }
                })
            }
            doneButtonActive.accept(out)
        }
    }
    
    internal func save(_ value: String?, for key: String) {
        vcardStructure.forEach {
            if $0.key == key {
                $0.value = value ?? ""
                validate()
            }
        }
        datasource.forEach {
            $0.childs.forEach({ (item) in
                if item.key == key {
                    item.value = value ?? ""
                }
            })
        }
        if key == "ci_nickname_temp" && value != nil {
            nickname = value!
            if let index = datasource.firstIndex(where: {$0.title == "Nickname".localizeString(id: "vcard_nick_name", arguments: [])}) {
                tableView.reloadRows(at: [IndexPath(row: 0, section: index)], with: .none)
            }
        }
    }
    
    internal func onProfileChanged(_ key: String, value: String?) {
        save(value, for: key)
    }
    
    internal func onSave() {
        dismissKeyboard()
        let out: [VCardManager.VCardMetaItem] = vcardStructure.map { (item) -> VCardManager.VCardMetaItem in
            return VCardManager.VCardMetaItem(title: item.title, value: item.value, key: item.key)
        }
        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
            user.vcards.createFromDatasource(items: out)
            user.vcards.update(stream)
        })
        navigationController?.popViewController(animated: true)
    }
    
    internal func onAvatarButtonDidPress() {
        let alert = UIAlertController(title: "Change profile picture".localizeString(id: "account_change_profile_picture", arguments: []), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Open camera".localizeString(id: "account_open_camera", arguments: []), style: .default, handler: { (_) in
            self.openCamera()
        }))
        alert.addAction(UIAlertAction(title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), style: .default, handler: { (_) in
            self.openGallery()
        }))
        alert.addAction(UIAlertAction(title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), style: .default, handler: { (_) in
            self.openAvatarPicker()
        }))
        alert.addAction(UIAlertAction(title: "Clear".localizeString(id: "clear", arguments: []), style: .destructive, handler: { (_) in
            self.clearAvatar()
        }))
        alert.addAction(UIAlertAction(title: "Cancel".localizeString(id: "cancel", arguments: []), style: .cancel, handler: { (_) in
            
        }))
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = view
                popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }
        present(alert, animated: true) {
            
        }
    }
    
    internal final func openAvatarPicker() {
        let vc = AvatarPickerViewController()
        vc.delegate = self
        vc.palette = nil
        vc.lastSettedEmoji = nil
        showModal(vc, from: self)
    }

    
    internal final func openCamera() {
        askPermision { (result) in
            DispatchQueue.main.async {
                if result && UIImagePickerController.isSourceTypeAvailable(.camera) {
                    let cameraPickerVC = UIImagePickerController()
                    cameraPickerVC.delegate = self
                    cameraPickerVC.sourceType = .camera
                    cameraPickerVC.allowsEditing = true
                    self.present(cameraPickerVC, animated: true, completion: nil)
                } else {
                    ErrorMessagePresenter()
                        .present(in: self,
                                 message: "To choose profile picture from camera, you should grant permission first".localizeString(id: "account_camera_permission", arguments: []),
                                 animated: true,
                                 completion: nil)
                }
            }
        }
    }
    
    internal final func openGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            let galleryPickerVC = UIImagePickerController()
            galleryPickerVC.delegate = self
            galleryPickerVC.sourceType = .photoLibrary
            galleryPickerVC.allowsEditing = true
            self.present(galleryPickerVC, animated: true, completion: nil)
        }
    }
    
    internal func clearAvatar() {
//        self.avatarImage = nil
        
//        do {
            let cell = tableView.cellForRow(at: IndexPath.init(row: 0, section: 0)) as? ProfileCell
            cell?.showDarkenedView()

//            let realm = try WRealm.safe()
            
            if owner == "" {
                owner = jid
            }
//            
//            guard let avatar = realm.object(ofType: AvatarStorageItem.self,
//                                            forPrimaryKey: [jid, owner].prp()),
//                  let url = avatar.uploadUrl,
//                  let previousHash = avatar.imageHash,
//                  let uuidFirstPart = UUID().uuidString.split(separator: "_").first else { return }
//            let hash = previousHash + "#" + uuidFirstPart
//            
//            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                session.avatarUploader?.sendClearMetadata(stream) {
//                    DefaultAvatarManager.shared.deleteAvatar(jid: self.jid, owner: self.owner)
//                    self.afterSettingAvatar()
//                }
//            }, fail: {
                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                    DefaultAvatarManager.shared.deleteAvatar(jid: self.jid, owner: self.owner)
                    user.avatarUploader.sendClearMetadata(stream) {
//                        DefaultAvatarManager.shared.deleteAvatar(jid: self.jid, owner: self.owner)
                        self.afterSettingAvatar()
                    }
                })
//            })
//        } catch {
//            DDLogDebug("AccountInfoViewController+InfoScreenHeaderButtonDelegate: \(#function). \(error.localizedDescription)")
//        }
        
        self.tableView.reloadData()
        doneButtonActive.accept(true)
        avatarChanged = true
    }
    
    func afterSettingAvatar() {
//        let conf = LetterAvatarBuilderConfiguration()
//        conf.backgroundColors = [AccountColorManager.shared.palette(for: self.owner).tint500]
//        conf.size = DefaultAvatarManager.defaultSize
//        conf.username = "\(self.jid.first?.uppercased() ?? "")"
//        guard let image = UIImage.makeLetterAvatar(withConfiguration: conf) else { return }
//        DefaultAvatarManager.shared.dumbAvatar = image
        
        let cell = tableView.cellForRow(at: IndexPath.init(row: 0, section: 0)) as? ProfileCell
        cell?.hideDarkenedView()
        
//        didReceiveNewAvatar(image)
    }
    
    internal func askPermision(_ callback: @escaping ((Bool) -> Void)) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            callback(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                callback(granted)
            }
        case .denied, .restricted:
            callback(false)
            return
        @unknown default:
            callback(false)
        }
    }
    
    internal func didReceiveNewAvatar(_ image: UIImage) {
        let cell = self.tableView.cellForRow(at: IndexPath.init(row: 0, section: 0)) as? ProfileCell
        func beforeSettingAvatar() {
            DispatchQueue.main.async {
                cell?.showDarkenedView()
                self.tableView.reloadRows(at: [IndexPath.init(row: 0, section: 0)], with: .none)
            }
        }
        func afterSettingAvatar(image: UIImage?) {
            DispatchQueue.main.async {
                if let image = image {
                    self.avatarImage = image
                }
                cell?.hideDarkenedView()
                self.tableView.reloadRows(at: [IndexPath.init(row: 0, section: 0)], with: .none)
            }
        }
        if let index = datasource.firstIndex(where: { $0.kind == .profile }) {
            self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
        
        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
            DispatchQueue.global(qos: .background).async {
                beforeSettingAvatar()
                user.avatarUploader.setAvatar(image: image, successCallback: {
                    afterSettingAvatar(image: image)
                }, failureCallback: {
                    status, error in
                    afterSettingAvatar(image: nil)
                    DispatchQueue.main.async {
                        let errorMessage = "Unable to send file: out of Cloud Storage"//item.messageError
                        let itemsWithQuota = [
                            ActionSheetPresenter.Item(destructive: false, title: "Manage Cloud Storage", value: "quota")
                        ]
                        ActionSheetPresenter().present(
                            in: self,
                            title: "Avatar upload error",
                            message: errorMessage,
                            cancel: "Cancel",
                            values: itemsWithQuota,
                            animated: true) { value in
                                switch value {
                                    case "quota":
                                        let vc = CloudStorageViewController()
                                        vc.configure(jid: self.jid)
                                        self.navigationController?.pushViewController(vc, animated: true)
                                    default:
                                        break
                                }
                            }
                    }
                    DDLogDebug("AccountEditViewController+Flow: \(#function). Eror with uploading avatar.")
                })
            }
//            UserAvatarManagerBase.updateLocalAvatar(owner: self.jid, for: self.jid, username: user.username, with: self.avatarImage)
//            user.PEPAvatars.publish(stream)
        })
        avatarChanged = true
    }
    
}

extension AccountEditViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        self.didReceiveNewAvatar(image)
    }
    
    
}
