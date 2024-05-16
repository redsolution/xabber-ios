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
import XMPPFramework
import CocoaLumberjack
import Toast_Swift
import MaterialComponents.MDCPalettes
import AVFoundation

extension GroupchatInfoViewController: InfoScreenHeaderButtonDelegate {
    
    func shouldUpdateAvatar() -> UIImage? {
//        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//            user.PEPAvatars.refreshAvatar(jid: self.jid)
//        })
        let conf = LetterAvatarBuilderConfiguration()
        conf.username = self.nickname.uppercased()
        conf.size = DefaultAvatarManager.defaultSize
        conf.backgroundColors = [AccountColorManager.shared.palette(for: self.owner).tint600]
        guard let avatar = UIImage.makeLetterAvatar(withConfiguration: conf) else {
            DDLogDebug("error during generate default avatar for \(self.nickname)")
            return nil
        }
        return avatar
    }
    
    func onFirstButtonPressed() {
        openChat()
    }
    
    func onSecondButtonPressed() {
        if canInvite {
            onInvite()
        }
    }
    
    func onThirdButtonPressed() {
        onChangeNotifications()
    }
    
    func onFourthButtonPressed() {
        onLeave()
    }
    
    func onImageButtonPressed() {
        if !self.canChangeAvatar { return }
        self.onChangeAvatar()
    }
    
    func onTitleButtonPressed() {
        print(#function)
    }
    
    internal func editCircles() {
        self.shouldResetNavbar = false
        let vc = EditContactViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.isGroupchat = true
        vc.isCircleSelectView = true
        showModal(vc, from: self)
    }
    
    internal func openChat() {
        let chatVc = ChatViewController()
        chatVc.owner = self.owner
        chatVc.jid = self.jid
        chatVc.conversationType = .group
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        if let rootVc = navigationController?.viewControllers.first {
            navigationController?.setViewControllers([rootVc, chatVc], animated: true)
        } else {
            navigationController?.pushViewController(chatVc, animated: true)
        }
    }
    
    internal func onInvite() {
        shouldResetNavbar = false
        let vc = GroupchatInviteViewController()
        vc.configure(jid: self.jid, owner: self.owner)
        showModal(vc, from: self)
    }
    
    internal func onChangeNotifications() {
        if isMuted {

            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                _ = user.syncManager.update(stream, jid: self.jid, conversationType: .group, mute: nil)
            })
            
        } else {
            let muteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 15 minutes".localizeString(id: "mute_15_min", arguments: []), value: "mute_15_min"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 1 hour".localizeString(id: "mute_1_hour", arguments: []), value: "mute_1_hour"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 2 hours".localizeString(id: "mute_2_hours", arguments: []), value: "mute_2_hours"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 1 day".localizeString(id: "mute_1_day", arguments: []), value: "mute_1_day"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute forever".localizeString(id: "mute_forever", arguments: []), value: "mute_forever"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: nil,
                message: nil,
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: muteItems,
                animated: true
            ) { value in
                var expiredAt: Double? = nil
                switch value {
                case "mute_15_min": expiredAt = 15 * 60
                case "mute_1_hour": expiredAt = 60 * 60
                case "mute_2_hours": expiredAt = 2 * 60 * 60
                case "mute_1_day": expiredAt = 24 * 60 * 60
                case "mute_forever": expiredAt = 0
                default: break
                }
                

                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        _ = user.syncManager.update(stream, jid: self.jid, conversationType: .group, mute: expiredAt)
                    })
                
            }
        }
    }
    
    internal func onLeave() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: GroupChatStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.name ?? jid
            let leaveItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Leave".localizeString(id: "groupchat_leave", arguments: []), value: "leave"),
                ActionSheetPresenter.Item(destructive: true, title: "Leave and block".localizeString(id: "groupchats_leave_block", arguments: []), value: "leave_and_block"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Leave group".localizeString(id: "groupchat_leave_full", arguments: []),
                message: "Do you really want to leave group \(displayedName)?".localizeString(id: "groupchat_leave_confirm", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: leaveItems,
                animated: true,
                completion: onLeaveCallback
            )
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onLeaveCallback(_ action: String) {
        switch action {
        case "leave":
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.leave(stream, groupchat: self.jid, callback: self.onLeaveResultCallback)
            })
        case "leave_and_block":
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.leave(stream, groupchat: self.jid, callback: self.onLeaveResultCallback)
            })
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.blocked.blockContact(stream, jid: self.jid)
            })
        default: break
        }
    }
    
    internal func onLeaveResultCallback(_ error: String?) {
        if let error = error {
            var message: String = ""
            switch error {
            case "fail": message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
            case "not-allowed": message = "Last owner can`t leave chat. Please transfer owner rights to somebody".localizeString(id: "groupchats_last_owner_leave_error", arguments: [])
            default: message = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
            }
            DispatchQueue.main.async {
                ErrorMessagePresenter().present(in: self, message: message, animated: true, completion: nil)
            }
        } else {
            DispatchQueue.main.async {
                self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                self.navigationController?.navigationBar.shadowImage = nil
                self.navigationController?.popToRootViewController(animated: true)
            }
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.afterLeave(groupchat: self.jid)
            })
        }
    }
    
    func showSettings() {
        self.shouldResetNavbar = false
        let vc = GroupchatSettingsViewController()
        vc.isStatus = false
        vc.configure(self.owner, jid: self.jid)
        showModal(vc, from: self)
//        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//        self.navigationController?.navigationBar.shadowImage = nil
//        navigationController?.pushViewController(vc, animated: true)
    }
    
    func showDefaultRestrictions() {
//        self.shouldResetNavbar = false
        let vc = GroupchatDefaultRightsViewController()
        vc.configure(self.owner, jid: self.jid)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func showInvitations() {
        let vc = GroupchatInviteListViewController()
        vc.configure(jid, owner: owner)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func showBlocked() {
//        self.shouldResetNavbar = false
        let vc = GroupchatBlockedViewController()
        vc.configure(jid, owner: owner)
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func setStatus() {
        self.shouldResetNavbar = false
        let vc = GroupchatSettingsViewController()
        vc.isStatus = true
        vc.entity = self.isIncognitoChat ? .incognitoChat : .groupchat
        vc.configure(self.owner, jid: self.jid)
        showModal(vc, from: self)
//        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//        self.navigationController?.navigationBar.shadowImage = nil
//        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc
    func showQRCode() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: GroupChatStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.name ?? jid
            let vc = QRCodeViewController()
            vc.username = displayedName
            vc.jid = self.jid
            vc.stringValue = "xmpp:\(self.jid)"
            showModal(vc, from: self)
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func clearHistory() {
        let deleteItems: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: true, title: "Clear".localizeString(id: "clear", arguments: []), value: "delete"),
        ]
        let message = "All message history in this group will be cleared. This action can not be undone.".localizeString(id: "clear_group_chat_history_dialog_message", arguments: [])
        ActionSheetPresenter().present(
            in: self,
            title: "Clear history".localizeString(id: "clear_history", arguments: []),
            message: message,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: deleteItems,
            animated: true
        ) { (value) in
            switch value {
            case "delete":
                self.view.makeToastActivity(ToastPosition.center)
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.retract?.deleteMessageGroupchat(stream, chat: self.jid)
                    { (error, result) in
                        DispatchQueue.main.async {
                            self.view.hideToastActivity()
                        }
                        if result {
                            DispatchQueue.main.async {
                                self.view.makeToast("All message history for this chat was deleted".localizeString(id: "groupchats_message_history_deleted_message", arguments: []))
                                self.navigationController?.popToRootViewController(animated: true)
                            }
                        } else {
                            DispatchQueue.main.async {
                                if let error = error {
                                    self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                }
                            }
                        }
                    }
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.msgDeleteManager
                            .deleteMessageGroupchat(stream, chat: self.jid)
                            { (error, result) in
                                DispatchQueue.main.async {
                                    self.view.hideToastActivity()
                                }
                                if result {
                                    DispatchQueue.main.async {
                                        self.view.makeToast("All message history for this chat was deleted".localizeString(id: "groupchats_message_history_deleted_message", arguments: []))
                                        self.navigationController?.popToRootViewController(animated: true)
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        if let error = error {
                                            self.view.makeToast("Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"]))
                                        }
                                    }
                                }
                            }
                    })
                })
            default:
                break
            }
        }
    }
    
    func exportHistory() {
        self.view.makeToast("History export is not implemented yet".localizeString(id: "history_export_not_implemented", arguments: []))
    }
    
    func openSearch() {
        let chatVc = ChatViewController()
        chatVc.owner = self.owner
        chatVc.jid = self.jid
        chatVc.conversationType = .group
        chatVc.inSearchMode.accept(true)
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        if let rootVc = navigationController?.viewControllers.first {
            navigationController?.setViewControllers([rootVc, chatVc], animated: true)
        } else {
            navigationController?.pushViewController(chatVc, animated: true)
        }
    }
    
    private final func showGroupInfo() {
        let vc = GroupchatInfoViewControllerSecondary()
        vc.owner = self.owner
        vc.jid = self.jid
        vc.isViewForAdmin = self.canBeChanged
        if self.canBeChanged && self.groupEditFormValues == nil {
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                _ = session
                    .groupchat?
                    .requestChatSettingsForm(
                        stream,
                        groupchat: self.jid,
                        callback: self.onChatSettingsFormResponse
                    )
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    _ = user.groupchats
                        .requestChatSettingsForm(
                            stream,
                            groupchat: self.jid,
                            callback: self.onChatSettingsFormResponse
                        )
                })
            }
            return
        }
        if let dict = self.groupEditFormValues {
            if let membershipValues = (dict.first(where: { ($0["var"] as? String) == "membership" })?["options"] as? [[String: String?]])?
                .compactMap ({
                    item -> [String: String] in
                    return ["label": item["label"]!!, "value": item["value"]!!]
                }) {
                vc.membershipValues = membershipValues
            }
            if let indexValues = (dict.first(where: { ($0["var"] as? String) == "index" })?["options"] as? [[String: String?]])?
                .compactMap ({
                    item -> [String: String] in
                    return ["label": item["label"]!!, "value": item["value"]!!]
                }) {
                vc.indexValues = indexValues
            }
            if let privacyValues = (dict.first(where: { ($0["var"] as? String) == "privacy" })?["options"] as? [[String: String?]])?
                .compactMap ({
                    item -> [String: String] in
                    return ["label": item["label"]!!, "value": item["value"]!!]
                }) {
                vc.privacyValues = privacyValues
            }
            vc.formData = dict
        }
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc
    internal func groupchatInfo(_ sender: UIBarButtonItem) {
        showGroupInfo()
    }
    
    private final func onChatSettingsFormResponseRuntime(values: [[String: Any]]?, error: String?) {
        self.onChatSettingsFormResponse(values: values, error: error)
        
    }
    
    func onChangeAvatar() {
        let groupchatItems = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera"),
            ActionSheetPresenter.Item(destructive: true, title: "Clear avatar".localizeString(id: "account_clear_avatar", arguments: []), value: "clear")
        ]
        ActionSheetPresenter().present(in: self,
                                       title: nil,
                                       message: nil,
                                       cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                                       values: groupchatItems,
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
        if self.canChangeAvatar {
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
        } else {
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
        showModal(vc, from: self)
    }
    
    internal final func onOpenEmojiPicker() {
        openAvatarPicker()
    }
    
    internal final func onOpenCamera() {
        openCamera()
    }
    
    internal final func onOpenGallery() {
        openGallery()
    }
    
    internal final func onClearAvatar() {
        onUpdateAvatar(nil)
    }
    
    func onUpdateAvatar(_ image: UIImage?) {
        DispatchQueue.main.async {
            self.view.makeToastActivity(.center)
        }
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            user.groupchats.publishAvatar(stream,
                                          groupchat: self.jid,
                                          groupAvatar: true,
                                          image: image,
                                          callback: self.onUpdateAvatarCallback)
        })
    }
    
    func onUpdateAvatarCallback(_ error: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
            if let error = error {
                var message: String = ""
                switch error {
                case "not-allowed":
                    message = "You have no permission to change member`s avatar".localizeString(id: "groupchats_member_avatar_no_permission", arguments: [])
                case "fail":
                    message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
                default:
                    message = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
                }
                ErrorMessagePresenter().present(in: self,
                                                message: message,
                                                animated: true,
                                                completion: nil)
            } else {
                
            }
        }
        
    }
    
    func onVerifyButtonPressed() {
        
    }
}

extension GroupchatInfoViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        self.onUpdateAvatar(image)
    }
}
