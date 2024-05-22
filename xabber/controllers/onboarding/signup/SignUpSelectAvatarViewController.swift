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
import RealmSwift
import CocoaLumberjack
import AVFoundation

class SignUpSelectAvatarViewController: SignUpBaseViewController {
    
    private let avatarGroupView: UIView = {
        let view = UIView(frame: CGRect(square: 180))
        
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        
        return view
    }()
    
    private let avatarButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 176))
        
        button.backgroundColor = UIColor(red: 227/255, green: 242/255, blue: 253/255, alpha: 1.0)
        
        button.setImage(#imageLiteral(resourceName: "avatar_gen_placeholder_128dp").withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .white
        
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            button.mask = UIImageView(image: image)
        } else {
            button.mask = nil
        }
        
        return button
    }()
    
    private let cameraButton: UIButton = {
        let button = UIButton(frame: CGRect(origin: CGPoint(x: 106, y: 106), size: CGSize(square: 64)))
        
        button.layer.cornerRadius = button.frame.width / 2
        button.backgroundColor = .systemBlue
        button.setImage(#imageLiteral(resourceName: "avatar_gen_camera_36dp").withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .white
        
        return button
    }()
    
    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .gray)
        
        view.startAnimating()
        
        return view
    }()
    
    private var avatarImage: UIImage? = nil
    
    private var avatarEmoji: String? = nil
    private var avatarPalette: MDCPalette? = nil
    
    override func configure() {
        self.navigationItem.hidesBackButton = true
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.setNeedsLayout()
        let skipButton = UIBarButtonItem(title: "Skip".localizeString(id: "skip", arguments: []), style: .done, target: self, action: #selector(onSkipButtonTouchUp))
        navigationItem.setRightBarButton(skipButton, animated: true)
        textField.isHidden = true
        navigationController?.isNavigationBarHidden = false
        avatarButton.addTarget(self, action: #selector(onButtonTouchUpInside), for: .touchUpInside)
        cameraButton.addTarget(self, action: #selector(onButtonTouchUpInside), for: .touchUpInside)
        makeButtonDisabled(false)
        button.addTarget(self, action: #selector(onSaveButtonTouchUpInside), for: .touchUpInside)
    }
    
    override func subscribe() {
        
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        avatarGroupView.addSubview(avatarButton)
        avatarGroupView.addSubview(cameraButton)
        stack.subviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(avatarGroupView)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(UIStackView())
    }
    
    
    override func activateConstraints() {
//        super.activateConstraints()
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 375),
            avatarGroupView.widthAnchor.constraint(equalToConstant: 180),
            avatarGroupView.heightAnchor.constraint(equalToConstant: 180),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.leftAnchor.constraint(equalTo: stack.leftAnchor, constant: 0),
            button.rightAnchor.constraint(equalTo: stack.rightAnchor, constant: 0)
        ])
        stack.setCustomSpacing(48, after: titleLabel)
        stack.setCustomSpacing(48, after: avatarGroupView)
    }
    
    override func onAppear() {
        super.onAppear()
        title = "Profile image".localizeString(id: "xmpp_login__registration_header_avatar", arguments: [])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        if let image = UIImage(named: AccountMasksManager.shared.mask176pt), AccountMasksManager.shared.load() != "square" {
            avatarButton.mask = UIImageView(image: image)
        } else {
            avatarButton.mask = nil
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let jid = metadata["jid"],
              let nickname = metadata["nickname"] else {
            return
        }
        AccountManager.shared.find(for: jid)?.delayedAction(delay: 1, toExecute: { user, stream in
            user.vcards.setSelfNickname(stream, nickname: nickname)
        })
    }
    
    override func localizeResources() {
        super.localizeResources()
        titleLabel.text = "Nice! Now set up a profile image best representing your identity.".localizeString(id: "xmpp_login__registration_title_avatar", arguments: [])
        button.setTitle("Save".localizeString(id: "save", arguments: []), for: .normal)
        button.setTitle("Save".localizeString(id: "save", arguments: []), for: .disabled)
    }
    
    override func onButtonTouchUp() {
        FeedbackManager.shared.tap()
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: "Emojis are not for boring people".localizeString(id: "registration_title_emojis_not_boring", arguments: []),
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: [
                ActionSheetPresenter.Item(destructive: false, title: "Use Emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
                ActionSheetPresenter.Item(destructive: false, title: "Choose Image".localizeString(id: "account_profile_image_button", arguments: []), value: "gallery"),
                ActionSheetPresenter.Item(destructive: false, title: "Take Selfie".localizeString(id: "account_webcam_profile_image_button", arguments: []), value: "camera")
            ],
            animated: true) { result in
            switch result {
            case "emoji":
                self.onEmojiSelected()
                break
            case "camera":
                self.onCameraSelected()
                break
            case "gallery":
                self.onGallerySelected()
                break
            default:
                break
            }
        }
    }
    
    private final func goNext() {
        if CommonConfigManager.shared.config.required_touch_id_or_password {
            let vc = PasscodeViewController(isOnboarding: true)
            self.navigationController?.setViewControllers([vc], animated: true)
        } else {
            let vc = SignUpEnableNotificationsViewController()
            self.navigationController?.setViewControllers([vc], animated: true)
        }
    }
    
    @objc
    private func onButtonTouchUpInside(_ sender: UIButton) {
        self.onButtonTouchUp()
    }
    
    @objc
    private final func onSaveButtonTouchUpInside(_ sender: UIButton) {
        guard let jid = metadata["jid"] else {
            return
        }
        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
            user.avatarUploader.setAvatar(image: self.avatarImage, successCallback: {
                AccountManager.shared.find(for: jid)?.action({ user, stream in
                    user.cloudStorage.getStats()
                })
            }, failureCallback: {
                status, error in
                
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
                                    vc.configure(jid: self.owner)
                                    self.navigationController?.pushViewController(vc, animated: true)
                                default:
                                    break
                            }
                        }
                }
                DDLogDebug("AccountInfoVC, InfoScreenButtonDelegate: \(#function). Fail to set avatar.")
            })
        })
        self.goNext()
//        AccountManager.shared.find(for: jid)?.action({ (user, stream) in
//            UserAvatarManagerBase.updateLocalAvatar(owner: jid, for: jid, username: user.username, with: self.avatarImage)
//            user.PEPAvatars.publish(stream)
//        })
//        goNext()
    }
    
    internal func askCameraPermision(_ callback: @escaping ((Bool) -> Void)) {
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
        askCameraPermision { (result) in
            DispatchQueue.main.async {
                if result && UIImagePickerController.isSourceTypeAvailable(.camera) {
                    let cameraPickerVC = UIImagePickerController()
                    cameraPickerVC.delegate = self
                    cameraPickerVC.sourceType = .camera
                    cameraPickerVC.cameraDevice = .front
                    cameraPickerVC.allowsEditing = true
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
    
    private final func openAvatarPicker() {
        let vc = AvatarPickerViewController()
        vc.delegate = self
        vc.palette = avatarPalette
        vc.lastSettedEmoji = avatarEmoji
        showModal(vc, from: self)
    }
    
    private final func onEmojiSelected() {
        openAvatarPicker()
    }
    
    private final func onCameraSelected() {
        openCamera()
    }
    
    private final func onGallerySelected() {
        openGallery()
    }
    
    private final func onReceiveImage(_ image: UIImage) {
        self.avatarImage = image
//        avatarButton.imageView!.layer.cornerRadius = 170 / 2
        avatarButton.setImage(image, for: .normal)
        avatarButton.layoutIfNeeded()
        DispatchQueue.main.async {
            self.makeButtonEnabled(true)
        }
    }
    
    @objc
    private final func onSkipButtonTouchUp(_ sender: UIBarButtonItem) {
        goNext()
    }
    
}

extension SignUpSelectAvatarViewController: UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
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
            self.onReceiveImage(image)
        }
    }
}

extension SignUpSelectAvatarViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        self.onReceiveImage(image)
        self.avatarEmoji = emoji
        self.avatarPalette = currentPalette
        UIView.animate(withDuration: 0.33, delay: 0.0, options: [.curveEaseIn]) {
            if let palette = currentPalette {
                self.avatarButton.backgroundColor = palette.tint50
            } else {
                self.avatarButton.backgroundColor = UIColor(red: 227/255, green: 242/255, blue: 253/255, alpha: 1.0)
            }
        } completion: { _ in
            
        }
    }
}
