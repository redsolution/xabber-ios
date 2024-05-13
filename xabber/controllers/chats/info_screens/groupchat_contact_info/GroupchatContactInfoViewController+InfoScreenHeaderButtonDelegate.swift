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
import CocoaLumberjack
import Toast_Swift
import LetterAvatarKit
import MaterialComponents.MDCPalettes
import AVFoundation

extension GroupchatContactInfoViewController: InfoScreenHeaderButtonDelegate {
    
    func shouldUpdateAvatar() -> UIImage? {
//        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//            user.PEPAvatars.refreshAvatar(groupchat: self.jid, userId: self.userId)
//        })
        let conf = LetterAvatarBuilderConfiguration()
        conf.username = self.userNickname.uppercased()
        conf.size = DefaultAvatarManager.defaultSize
        conf.backgroundColors = [AccountColorManager.shared.palette(for: owner).tint600]
        guard let avatar = UIImage.makeLetterAvatar(withConfiguration: conf) else {
            DDLogDebug("error during generate default avatar for \(self.userNickname)")
            return nil
        }
        return avatar
    }
    
    func onFirstButtonPressed() {
        if isIncognitoGroup {
            if isMyProfile {
                DispatchQueue.main.async {
                    self.view.makeToast("Can`t create private chat with yourself".localizeString(id: "chat_cant_create_private_yourself", arguments: []))
                }
            } else {
                openPrivateChat()
            }
        } else {
            if isMyProfile {
                DispatchQueue.main.async {
                    self.view.makeToast("Can`t create direct chat with yourself".localizeString(id: "chat_cant_create_direct_yourself", arguments: []))
                }
            } else {
                openChat()
            }
        }
    }
    
    func onSecondButtonPressed() {
        showMessages()
    }
    
    func onThirdButtonPressed() {
        if !self.canChangeBadge { return }
        TextViewPresenter().present(
            in: self,
            title: "Change member`s badge".localizeString(id: "groupchats_create_members_badge", arguments: []),
            message: "", cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Change".localizeString(id: "change", arguments: []),
            currentValue: self.userBadge,
            animated: true
            ) { (value) in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.groupchat?
                    .changeUserData(
                        stream,
                        groupchat: self.jid,
                        userId: self.userId,
                        badge: value
                    ) { (error) in
                        self.onUserDataChanged(error, value: value)
                    }
                }) {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.groupchats
                            .changeUserData(
                                stream,
                                groupchat: self.jid,
                                userId: self.userId,
                                badge: value
                            ) { (error) in
                                self.onUserDataChanged(error, value: value)
                            }
                        })
                }
                
            }
    }
    
    func onUserDataChanged(_ error: String?, value: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
        if let error = error {
            DispatchQueue.main.async {
                var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                switch error {
                case "not-allowed": message = "You don't have permission to change badge".localizeString(id: "groupchats_no_badge_permission", arguments: [])
                default: break
                }
                self.view.makeToast(message)
            }
        } else {
            do {
                let realm = try  WRealm.safe()
                try realm.write {
                    realm.object(ofType: GroupchatUserStorageItem.self,
                                 forPrimaryKey: [self.userId, self.jid, self.owner].prp())?
                    .badge = value ?? ""
                }
            } catch {
                DDLogDebug("GroupchatContactInfoViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    func onFourthButtonPressed() {
        if self.isBlocked {
            onUnblock()
        } else {
            if self.isKicked {
                onBlock()
            } else {
                onKick()
            }
        }
        
    }
    
    func onImageButtonPressed() {
        onChangeAvatar()
    }
    
    func onTitleButtonPressed() {
        if !self.canChangeNickname { return }
        TextViewPresenter().present(
            in: self,
            title: "Change member`s nickname".localizeString(id: "groupchats_change_nickname", arguments: []),
            message: "",
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Change".localizeString(id: "change", arguments: []),
            currentValue: self.userNickname,
            animated: true
            ) { (value) in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.groupchat?
                        .changeUserData(
                            stream,
                            groupchat: self.jid,
                            userId: self.userId,
                            nickname: value
                        ) { (error) in
                            DispatchQueue.main.async {
                                self.view.hideToastActivity()
                            }
                            if let error = error {
                                DispatchQueue.main.async {
                                    var message: String = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                                    switch error {
                                    case "not-allowed": message = "You don't have permission to change nickname".localizeString(id: "groupchats_nickname_change_no_permission", arguments: [])
                                    case "fail": message = "Internal error: missed connection".localizeString(id: "groupchats_error_missed_connection", arguments: [])
                                    default: break
                                    }
                                    self.view.makeToast(message)
                                }
                            }
                        }
                }) {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.groupchats
                            .changeUserData(
                                stream,
                                groupchat: self.jid,
                                userId: self.userId,
                                nickname: value
                            ) { (error) in
                                DispatchQueue.main.async {
                                    self.view.hideToastActivity()
                                }
                                if let error = error {
                                    DispatchQueue.main.async {
                                        var message: String = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                                        switch error {
                                        case "not-allowed": message = "You don't have permissions to change nickname".localizeString(id: "groupchats_nickname_change_no_permission", arguments: [])
                                        case "fail": message = "Internal error: missed connection".localizeString(id: "groupchats_error_missed_connection", arguments: [])
                                        default: break
                                        }
                                        self.view.makeToast(message)
                                    }
                                }
                            }
                    })
                }
                
            }
    }
    
    internal func openPrivateChat() {
        self.view.makeToastActivity(ToastPosition.center)
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.createPeerToPeer(stream, groupchat: self.jid, user: self.userId, callback: self.onCreatePrivateChat)
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.createPeerToPeer(stream, groupchat: self.jid, user: self.userId, callback: self.onCreatePrivateChat)
            })
        })

    }
    
    @objc
    internal func onCreatePrivateChat(_ error: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if error == "success" {
                self.view.hideToastActivity()
            } else if error == "conflict" {
                self.view.hideToastActivity()
                self.view.makeToast("Private chat with member already exist".localizeString(id: "groupchats_private_chat_exists", arguments: []))
            } else {
                self.view.hideToastActivity()
                self.view.makeToast("Internal error".localizeString(id: "message_manager_error_internal", arguments: []))
            }
        }
        
    }
    
    internal func openChat() {
        do {
            let realm = try  WRealm.safe()
            if let jid = realm.object(ofType: GroupchatUserStorageItem.self,
                                      forPrimaryKey: [self.userId, self.jid, self.owner].prp())?.jid,
                jid.isNotEmpty {
                let chatVc = ChatViewController()
                chatVc.owner = self.owner
                chatVc.jid = jid
                navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                navigationController?.navigationBar.shadowImage = nil
                if let rootVc = navigationController?.viewControllers.first {
                    navigationController?.setViewControllers([rootVc, chatVc], animated: true)
                } else {
                    navigationController?.pushViewController(chatVc, animated: true)
                }
            }
        } catch {
            DDLogDebug("GroupchatContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    internal func showMessages() {
//        let vc = GroupchatContactMessagesViewController()
//        vc.configure(userId: self.userId, jid: self.jid, owner: self.owner)
        let vc = GroupChatMessagesByUserViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.userId = self.userId
        let nvc = UINavigationController(rootViewController: vc)
        nvc.modalPresentationStyle = .fullScreen
        nvc.modalTransitionStyle = .coverVertical
        self.definesPresentationContext = true
        self.present(nvc, animated: true, completion: nil)
    }
    
    internal func onBlock() {
        do {
            let realm = try  WRealm.safe()
            let displayedName = realm.object(ofType: GroupchatUserStorageItem.self,
                                             forPrimaryKey: [self.userId, self.jid, self.owner].prp())?.nickname ?? "member"
            let blockItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Block".localizeString(id: "contact_bar_block", arguments: []), value: "block"),
            ]
            
            ActionSheetPresenter().present(
                in: self,
                title: "Block member".localizeString(id: "groupchat__dialog_block_member__header", arguments: []),
                message: "Do you really want to block member \(displayedName)?".localizeString(id: "groupchat__dialog_block_member__confirm", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: blockItems,
                animated: true
            ) { value in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                switch value {
                case "block":
                    XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                        session.groupchat?.blockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onBlockResult)
                    }) {
                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                            user.groupchats.blockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onBlockResult)
                        })
                    }
                    
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onUnblock() {
        do {
            let realm = try  WRealm.safe()
            let displayedName = realm.object(ofType: GroupchatUserStorageItem.self,
                                             forPrimaryKey: [self.userId, self.jid, self.owner].prp())?.nickname ?? "member"
            let unblockItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Unblock".localizeString(id: "groupchat_unblock", arguments: []), value: "unblock"),
            ]
            
            ActionSheetPresenter().present(
                in: self,
                title: "Unblock member".localizeString(id: "groupchats_unblock_member", arguments: []),
                message: "Do you really want to unblock member \(displayedName)?".localizeString(id: "unblock_contact_confirm_short", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: unblockItems,
                animated: true
            ) { value in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                switch value {
                case "unblock":
                    XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                        session.groupchat?.unblockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onUnblockResults)
                    }) {
                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                            user.groupchats.unblockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onUnblockResults)
                        })
                    }
                    
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onKick() {
        do {
            let realm = try  WRealm.safe()
            let displayedName = realm.object(ofType: GroupchatUserStorageItem.self,
                                             forPrimaryKey: [self.userId, self.jid, self.owner].prp())?.nickname ?? "member"
            let kickItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Kick".localizeString(id: "groupchat_kick", arguments: []), value: "kick"),
                ActionSheetPresenter.Item(destructive: true, title: "Kick and Block".localizeString(id: "groupchat_kick_and_block", arguments: []), value: "block"),
            ]
            
//            let bloclItems: []
            
            ActionSheetPresenter().present(
                in: self,
                title: "Kick member".localizeString(id: "groupchat_kick_member", arguments: []),
                message: "Do you really want to kick member \(displayedName)?".localizeString(id: "groupchat_do_you_really_want_to_kick_membername", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: kickItems,
                animated: true
            ) { value in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                switch value {
                case "kick":
                    XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                        session.groupchat?.kickUser(stream, groupchat: self.jid, userId: self.userId, callback: self.onKickResult)
                    }) {
                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                            user.groupchats.kickUser(stream, groupchat: self.jid, userId: self.userId, callback: self.onKickResult)
                        })
                    }
                    
                case "block":
                    XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                        session.groupchat?.blockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onBlockResult)
                    }) {
                        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                            user.groupchats.blockUser(stream, groupchat: self.jid, ids: [self.userId], callback: self.onBlockResult)
                        })
                    }
                    
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onKickResult(_ error: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
        if let error = error {
            DispatchQueue.main.async {
                var message: String = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                switch error {
                case "not-allowed": message = "You don't have permissions to kick members".localizeString(id: "groupchat_no_kick_permission", arguments: [])
                case "fail": message = "Internal error: missed connection".localizeString(id: "groupchats_error_missed_connection", arguments: [])
                default: break
                }
                self.view.makeToast(message)
            }
        } else {
            
            DispatchQueue.main.async {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                                   forPrimaryKey: [self.userId, self.jid, self.owner].prp()) {
                        try realm.write {
                            if !instance.isInvalidated {
                                instance.isKicked = true
                            }
                        }
                    }
                } catch {
                    DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
                }
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
    
    internal func onUnblockResults(_ error: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
        if let error = error {
            DispatchQueue.main.async {
                var message: String = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                switch error {
                case "not-allowed": message = "You don't have permissions to unblock members".localizeString(id: "groupchats_no_unblock_permision", arguments: [])
                case "fail": message = "Internal error: missed connection".localizeString(id: "groupchats_error_missed_connection", arguments: [])
                default: break
                }
                self.view.makeToast(message)
            }
        } else {
            
            DispatchQueue.main.async {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                                   forPrimaryKey: [self.userId, self.jid, self.owner].prp()) {
                        try realm.write {
                            if !instance.isInvalidated {
                                instance.isBlocked = false
                            }
                        }
                    }
                } catch {
                    DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
                }
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
    
    internal func onBlockResult(_ error: String?) {
           DispatchQueue.main.async {
               self.view.hideToastActivity()
           }
           if let error = error {
               DispatchQueue.main.async {
                   var message: String = "Internal error: \(error)".localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                   switch error {
                   case "not-allowed": message = "You don't have permissions to block members".localizeString(id: "groupchats_no_block_permission", arguments: [ ])
                   case "fail": message = "Internal error: missed connection".localizeString(id: "groupchats_error_missed_connection", arguments: [])
                   default: break
                   }
                   self.view.makeToast(message)
               }
           } else {
               
               DispatchQueue.main.async {
                   do {
                       let realm = try  WRealm.safe()
                       if let instance = realm.object(ofType: GroupchatUserStorageItem.self,
                                                      forPrimaryKey: [self.userId, self.jid, self.owner].prp()) {
                           try realm.write {
                               if !instance.isInvalidated {
                                   instance.isBlocked = true
                               }
                           }
                       }
                   } catch {
                       DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
                   }
                   self.navigationController?.popViewController(animated: true)
               }
           }
       }
    
    internal func onReceiveForm(form: [[String: Any]]?, permissions: [[String: Any]]?, restrictions: [[String: Any]]?, error: String?) {
        self.formDatasource = []
        if let form = form {
            self.form = form
        }
        func transformDatasource(_ item: [String: Any]) -> FormDatasource? {
            switch item["type"] as? String {
            case "fixed":
                guard let fieldName = item["var"] as? String,
                    !["permission", "restriction"].contains(fieldName),
                    self.isMyProfile else {
                        return nil
                }
                return FormDatasource(.fixed,
                                      itemId: item["var"] as? String ?? "",
                                      title: item["label"] as? String ?? "",
                                      value: item["value"] as? String,
                                      payload: item["values"] as? [[String: String]],
                                      item: item)
            case "boolean":
                return FormDatasource(.boolItem,
                                  itemId: item["var"] as? String ?? "",
                                  title: item["label"] as? String ?? "",
                                  item: item)
            case "list-single":
                return FormDatasource(.listItem,
                                  itemId: item["var"] as? String ?? "",
                                  title: item["label"] as? String ?? "",
                                  value: item["value"] as? String,
                                  payload: item["values"] as? [[String: String]],
                                  item: item)
            default: return nil
            }
        }
        
        
        
        DispatchQueue.main.async {
            self.formDatasource = []
            self.formSectionTitles = []
            if let form = permissions?.compactMap({ return transformDatasource($0) }), form.isNotEmpty {
                self.formDatasource.append(form)
                self.formSectionTitles.append("Permissions".localizeString(id: "groupchat_member_permissions", arguments: []))
            }
            
            if let form = restrictions?.compactMap({ return transformDatasource($0) }), form.isNotEmpty {
                self.formDatasource.append(form)
                self.formSectionTitles.append("Restrictions".localizeString(id: "groupchats_member_restrictions", arguments: []))
            }
            
            self.tableView.reloadData()
        }
    }
    
    internal func onSave() {
        inSaveMode.accept(true)
        var modifiedForm: [[String: Any]] = []
        form.forEach {
            item in
            if ["FORM_TYPE", "user-id"].contains((item["var"] as? String) ?? "") {
                modifiedForm.append(item)
            }
        }
        modifiedForm.append(contentsOf: changedValues.value)
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            self.updateFormId = session.groupchat?.updateForm(stream, formType: .userRights, groupchat: self.jid, userData: modifiedForm) { (error) in
                DispatchQueue.main.async {
                    if let error = error {
                        var message: String = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
                        if error == "fail" {
                            message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
                        }
                        self.view.makeToast(message)
                    } else {
                        self.changedValues.accept([])
                    }
                    self.inSaveMode.accept(false)
                }
            }
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                self.updateFormId = user.groupchats.updateForm(stream, formType: .userRights, groupchat: self.jid, userData: modifiedForm) { (error) in
                    DispatchQueue.main.async {
                        if let error = error {
                            var message: String = "Internal server error".localizeString(id: "error_internal_server", arguments: [])
                            if error == "fail" {
                                message = "Connection failed".localizeString(id: "grouchats_connection_failed", arguments: [])
                            }
                            self.view.makeToast(message)
                        } else {
                            self.changedValues.accept([])
                        }
                        self.inSaveMode.accept(false)
                    }
                }
            })
        }
        
    }
    
    func onChangeAvatar() {
        let myProfileItems = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera"),
            ActionSheetPresenter.Item(destructive: true, title: "Clear avatar".localizeString(id: "account_clear_avatar", arguments: []), value: "clear")
        ]
        let otherProfileItems = [
            ActionSheetPresenter.Item(destructive: true, title: "Clear avatar".localizeString(id: "account_clear_avatar", arguments: []), value: "clear")
        ]
        ActionSheetPresenter().present(in: self,
                                       title: nil,
                                       message: nil,
                                       cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                                       values: self.isMyProfile ? myProfileItems : otherProfileItems,
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
        if self.canChangeAvatars {
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
        onUpdateAvatar(nil)
    }
    
    func onUpdateAvatar(_ image: UIImage?) {
        DispatchQueue.main.async {
            self.view.makeToastActivity(.center)
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.publishAvatar(
                stream,
                groupchat: self.jid,
                groupAvatar: false,
                userId: self.isMyProfile ? "" : self.userId,
                image: image,
                callback: self.onUpdateAvatarCallback
            )
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.publishAvatar(stream,
                                              groupchat: self.jid,
                                              groupAvatar: false,
                                              userId: self.isMyProfile ? "" : self.userId,
                                              image: image,
                                              callback: self.onUpdateAvatarCallback)
            })
        }
        
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
                self.headerView.configure(
                    avatarUrl: nil, 
                    jid: self.jid,
                    owner: self.owner,
                    userId: self.userId,
                    title: self.userNickname,
                    subtitle: self.userJid,
                    thirdLine: nil,
                    titleColor: AccountColorManager.shared.primaryColor(for: self.owner)
                )
                self.tableView.reloadData()
            }
        }
    }
}

extension GroupchatContactInfoViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        onUpdateAvatar(image)
    }
}
