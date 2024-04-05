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
import RealmSwift
import LetterAvatarKit
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import AVFoundation

extension SettingsViewController: InfoScreenHeaderButtonDelegate {
    func shouldUpdateAvatar() -> UIImage? {
        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
//            user.PEPAvatars.refreshAvatar(jid: self.jid)
        })
        let conf = LetterAvatarBuilderConfiguration()
        conf.username = self.nickname.uppercased()
        conf.size = DefaultAvatarManager.defaultSize
        conf.backgroundColors = [AccountColorManager.shared.palette(for: jid).tint600]
        conf.useSingleLetter = true
        guard let avatar = UIImage.makeLetterAvatar(withConfiguration: conf) else {
            DDLogDebug("error during generate default avatar for \(self.nickname)")
            return nil
        }
        return avatar
    }
    
    func onFirstButtonPressed() {
        print(#function)
    }
    
    func onSecondButtonPressed() {
        print(#function)
    }
    
    func onThirdButtonPressed() {
        print(#function)
    }
    
    func onFourthButtonPressed() {
        print(#function)
    }
    
    func onImageButtonPressed() {
        onChangeAvatar()
    }
    
    func onTitleButtonPressed() {
        print(#function)
    }
    
    @objc func onQRCode() {
        do {
            let realm = try Realm()
            let displayedName = realm.object(ofType: AccountStorageItem.self,
                                             forPrimaryKey: jid)?.username ?? jid
            let vc = QRCodeViewController()
            vc.username = displayedName
            vc.jid = self.jid
            vc.stringValue = "xmpp:\(self.jid)"
            let nvc = UINavigationController(rootViewController: vc)
            nvc.modalPresentationStyle = .fullScreen
            nvc.modalTransitionStyle = .coverVertical
            self.definesPresentationContext = true
            self.present(nvc, animated: true, completion: nil)
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func onChangeAvatar() {
        let items = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera"),
            ActionSheetPresenter.Item(destructive: true, title: "Clear avatar".localizeString(id: "account_clear_avatar", arguments: []), value: "clear")
        ]
        ActionSheetPresenter().present(in: self,
                                       title: nil,
                                       message: nil,
                                       cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                                       values: items,
                                       animated: true) { (value) in
                                        switch value {
                                        case "camera": self.onOpenCamera()
                                        case "gallery": self.onOpenGallery()
                                        case "emoji": self.onOpenEmojiPicker()
                                        case "clear": self.onClearAvatar()
                                        default: break
                                        }
        }
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
    
    internal func openCamera() {
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
    
    internal func openGallery() {
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            let galleryPickerVC = UIImagePickerController()
            galleryPickerVC.delegate = self
            galleryPickerVC.sourceType = .photoLibrary
            galleryPickerVC.allowsEditing = true
            self.present(galleryPickerVC, animated: true, completion: nil)
        }
    }
    
    internal final func openAvatarPicker() {
        let vc = AvatarPickerViewController()
        vc.delegate = self
        vc.palette = nil
        vc.lastSettedEmoji = nil
        vc.modalTransitionStyle = .coverVertical
        vc.modalPresentationStyle = .overFullScreen
        present(vc, animated: true, completion: nil)
    }
    
    internal final func onOpenEmojiPicker() {
        openAvatarPicker()
    }
    
    func onOpenCamera() {
        openCamera()
    }
    
    func onOpenGallery() {
        openGallery()
    }
    
    func onClearAvatar() {
        self.beforeSettingAvatar()
        if owner == "" {
            owner = jid
        }
        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
            user.avatarUploader.sendClearMetadata(stream) {
                self.afterSettingAvatar(image: nil)
            }
        })
    }
    
    func onUpdateAvatar(_ image: UIImage?) {
        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
            self.beforeSettingAvatar()
            user.avatarUploader.setAvatar(image: image, successCallback: {
                do {
                    let realm = try WRealm.safe()
                    let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid)
                    DefaultAvatarManager.shared.getAvatar(url: account?.avatarMaxUrl, jid: self.jid, owner: self.jid, size: 128) { image in
                        if let image = image {
                            self.headerView.imageButton.setImage(image, for: .normal)
                        } else {
                            self.headerView.imageButton.setImage(UIImageView.getDefaultAvatar(for: self.jid, owner: self.jid, size: 256), for: .normal)
                        }
                        self.headerView.imageActivityIndicator.stopAnimating()
                        self.headerView.hideDarkenedView()
                    }
                } catch {
                    DDLogDebug("dsg")
                }
                AccountManager.shared.find(for: self.jid)?.action({ user, _ in
                    user.cloudStorage.getStats()
                })
            }, failureCallback: {
                status, error in
                do {
                    let realm = try WRealm.safe()
                    let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid)
                    DefaultAvatarManager.shared.getAvatar(url: account?.avatarMaxUrl, jid: self.jid, owner: self.jid, size: 128) { image in
                        if let image = image {
                            self.headerView.imageButton.setImage(image, for: .normal)
                        } else {
                            self.headerView.imageButton.setImage(UIImageView.getDefaultAvatar(for: self.jid, owner: self.jid, size: 256), for: .normal)
                        }
                        self.headerView.imageActivityIndicator.stopAnimating()
                        self.headerView.hideDarkenedView()
                    }
                } catch {
                    DDLogDebug("dsg")
                }
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
                DDLogDebug("SettingsViewController, InfoScreenButtonDelegate: \(#function). Fail to set avatar.")
            })
        })
    }
    
    func beforeSettingAvatar() {
        DispatchQueue.main.async {
            self.headerView.imageActivityIndicator.startAnimating()
            self.headerView.showDarkenedView()
        }
    }
    
    func afterSettingAvatar(image: UIImage?) {
        DispatchQueue.main.async {
            self.headerView.imageActivityIndicator.stopAnimating()
            self.headerView.hideDarkenedView()
            if image == nil {
//                let conf = LetterAvatarBuilderConfiguration()
//                conf.backgroundColors = [AccountColorManager.shared.palette(for: self.owner).tint500]
//                conf.size = DefaultAvatarManager.defaultSize
//                conf.username = "\(self.jid.first?.uppercased() ?? "")"
//                guard let image = UIImage.makeLetterAvatar(withConfiguration: conf) else { return }
//                self.headerView.imageButton.setImage(image.resize(targetSize: CGSize(square: 128)), for: .normal)
                self.headerView.imageButton.setImage(UIImageView.getDefaultAvatar(for: self.jid, owner: self.jid, size: 256), for: .normal)
            } else {
                self.headerView.imageButton.setImage(image?.resize(targetSize: CGSize(square: 128)), for: .normal)
            }
        }
    }
    
    internal func onDeleteAccount() {
        let presenter = QuitAccountPresenter(jid: jid)
        presenter.present(in: self, animated: true) {
            self.unsubscribe()
            AccountManager.shared.deleteAccount(by: self.jid)
            if AccountManager.shared.emptyAccountsList() {
                DispatchQueue.main.async {
                    let vc = OnboardingViewController()
                    let navigationController = UINavigationController(rootViewController: vc)
                    navigationController.isNavigationBarHidden = true
                    (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController = navigationController
                }
            } else {
                DispatchQueue.main.async {
                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                    self.navigationController?.navigationBar.shadowImage = nil
                    self.navigationController?.popToRootViewController(animated: true)
                }
            }
        }
    }
    
    func onVerifyButtonPressed() {
        
    }
}

extension SettingsViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        onUpdateAvatar(image)
    }
}

extension SettingsViewController: UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        guard let newImage = info[UIImagePickerController.InfoKey.editedImage] as? UIImage ?? info[UIImagePickerController.InfoKey.originalImage] as? UIImage else {
            DispatchQueue.main.async {
                self.view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
            return
        }
        var image = newImage
        if picker.sourceType == .camera {
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        }
        image = image.fixOrientation()
        picker.dismiss(animated: true) {
            self.onUpdateAvatar(image)
        }
    }
}
