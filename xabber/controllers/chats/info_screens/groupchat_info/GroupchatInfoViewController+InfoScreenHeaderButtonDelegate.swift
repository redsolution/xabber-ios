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
import MaterialComponents.MDCPalettes
import AVFoundation

extension GroupchatInfoViewController: InfoScreenHeaderDelegate {
    
    func onXabberAccount() {
        
    }
    
    func shouldUpdateAvatar() -> UIImage? {
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
        let vc = EditCirclesViewController()
        
        vc.jid = self.jid
        vc.owner = self.owner
        
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func openChat() {
        
        if leftMenuDelegate == nil {
            let chatVc = ChatViewController()
            chatVc.owner = self.owner
            chatVc.jid = self.jid
            chatVc.conversationType = .group
            showDetail(chatVc, currentVc: self)
        } else {
            self.leftMenuDelegate?.openChatlistWithChat(owner: self.owner, jid: self.jid, conversationType: .group, configure: nil)
            self.dismiss(animated: true) {
            }
        }
    }
    
    private func performAfterResolvedGroupchatInfoExit(_ perform: @escaping (UIViewController) -> Void) {
        let exitAction = NavigationExitPolicy.action(
            for: NavigationExitPolicyContext(destination: self, route: .currentNavigationPush)
        )
        let resolution = GroupchatInfoActionExitPolicy.resolve(
            currentController: self,
            presentingViewController: navigationController?.presentingViewController
                ?? presentationController?.presentingViewController
                ?? presentingViewController,
            exitAction: exitAction
        )

        guard resolution.action != .ignore,
              let routePresenter = resolution.routePresenter else {
            return
        }

        switch resolution.action {
        case .dismissThenPerform:
            dismiss(animated: true) {
                perform(routePresenter)
            }
        case .performImmediately:
            perform(routePresenter)
        case .ignore:
            break
        }
    }

    private func routeToGroupChat(configure: ((ChatViewController?) -> Void)?) {
        let route = InfoCardChatSearchRouting.route(
            owner: self.owner,
            jid: self.jid,
            conversationType: .group
        )

        performAfterResolvedGroupchatInfoExit { [weak self] routePresenter in
            guard let self else { return }

            if let currentChat = InfoCardChatSearchRouting.matchingCurrentChat(
                in: routePresenter,
                route: route
            ) {
                configure?(currentChat)
                return
            }

            if let leftMenuDelegate = self.leftMenuDelegate {
                leftMenuDelegate.openChatlistWithChat(
                    owner: route.owner,
                    jid: route.jid,
                    conversationType: route.conversationType,
                    configure: configure
                )
                return
            }

            let chatVc = InfoCardChatSearchRouting.makeChatViewController(
                for: route,
                configure: configure
            )
            showStacked(chatVc, in: routePresenter)
        }
    }

    internal func searchChat() {
        routeToGroupChat(configure: InfoCardChatSearchRouting.searchModeConfigurator())
    }
    
    internal func onInvite() {
        shouldResetNavbar = false
        let vc = GroupchatInviteViewController()
        vc.configure(jid: self.jid, owner: self.owner)
        self.navigationController?.pushViewController(vc, animated: true)
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
    
    @objc
    internal func onLeaveHeaderButtonTouchUpInside(_ sender: AnyObject) {
        self.onLeave()
    }
    
    internal func onLeave() {
        do {
            let repository = GroupRepository(realm: try WRealm.safe())
            let projection = try repository.projection(owner: owner, groupJID: jid)
            let displayedName = projection.state.snapshot.info?.name ?? jid
            let exitMode = try CanonicalGroupMembershipLifecycle.exitMode(
                owner: owner,
                groupJID: jid
            )
            let leaveItems: [ActionSheetPresenter.Item]
            let message: String
            switch exitMode {
            case .leave:
                leaveItems = [
                    ActionSheetPresenter.Item(
                        destructive: false,
                        title: "Leave".localizeString(id: "groupchat_leave", arguments: []),
                        value: "leave"
                    ),
                    ActionSheetPresenter.Item(
                        destructive: true,
                        title: "Leave and block".localizeString(id: "groupchats_leave_block", arguments: []),
                        value: "leave_and_block"
                    ),
                ]
                message = "Do you really want to leave group \(displayedName)?"
                    .localizeString(
                        id: "groupchat_leave_confirm",
                        arguments: ["\(displayedName)"]
                    )
            case .deletePeerToPeer:
                leaveItems = [
                    ActionSheetPresenter.Item(
                        destructive: true,
                        title: "Delete".localizeString(id: "delete", arguments: []),
                        value: "delete"
                    ),
                ]
                message = "Leaving this private group will permanently delete \(displayedName)."
                    .localizeString(
                        id: "groupchat_delete_p2p_confirm",
                        arguments: [displayedName]
                    )
            case .deleteLastOwner:
                leaveItems = [
                    ActionSheetPresenter.Item(
                        destructive: true,
                        title: "Delete".localizeString(id: "delete", arguments: []),
                        value: "delete"
                    ),
                ]
                message = "You are the last owner. Leaving now will permanently delete \(displayedName)."
                    .localizeString(
                        id: "groupchat_delete_last_owner_confirm",
                        arguments: [displayedName]
                    )
            }
            ActionSheetPresenter().present(
                in: self,
                title: exitMode.deletesGroup
                    ? "Delete".localizeString(id: "delete", arguments: [])
                    : "Leave group".localizeString(
                        id: "groupchat_leave_full",
                        arguments: []
                    ),
                message: message,
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
        guard ["leave", "leave_and_block", "delete"].contains(action),
              let account = AccountManager.shared.find(for: owner) else {
            if action.isNotEmpty {
                onLeaveResultCallback(.failure(GroupchatServiceError.notPrepared))
            }
            return
        }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            do {
                let exitMode = try CanonicalGroupMembershipLifecycle.exitMode(
                    owner: self.owner,
                    groupJID: self.jid
                )
                switch exitMode {
                case .leave:
                    try await CanonicalGroupMembershipLifecycle.leave(
                        account: account,
                        groupJID: self.jid
                    )
                case .deletePeerToPeer, .deleteLastOwner:
                    try await CanonicalGroupMembershipLifecycle.delete(
                        account: account,
                        groupJID: self.jid
                    )
                }
                if action == "leave_and_block" {
                    account.action { user, stream in
                        user.blocked.blockContact(stream, jid: self.jid)
                    }
                }
                self.onLeaveResultCallback(.success(()))
            } catch {
                self.onLeaveResultCallback(.failure(error))
            }
        }
    }
    
    internal func onLeaveResultCallback(_ result: Result<Void, Error>) {
        switch result {
        case let .failure(error):
            ErrorMessagePresenter().present(
                in: self,
                message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
                animated: true,
                completion: nil
            )
        case .success:
            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
            navigationController?.navigationBar.shadowImage = nil
            navigationController?.popToRootViewController(animated: true)
        }
    }
    
    @objc
    internal func onEditButtonTouchUpInside(_ sender: AnyObject) {
        self.showSettings()
    }
    
    func showSettings() {
        self.shouldResetNavbar = false
        let vc = GroupchatSettingsViewControllerT()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.leftMenuDelegate = self.leftMenuDelegate
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    func showInvitations() {
        let vc = GroupchatInviteListViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func showBlocked() {
        let vc = GroupchatBlockedViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func setStatus() {
        showSettings()
    }
    
    @objc
    func showQRCode() {
        let vc = QRCodeViewController()
        
        vc.username = self.nickname
        vc.jid = self.jid
        vc.stringValue = "xmpp:\(self.jid)"
        
        let avatarURL = currentProjection?.state.snapshot.info?.avatar?.url
        DefaultAvatarManager.shared.getAvatar(url: avatarURL, jid: jid, owner: owner, size: 56) { image in
            if let image = image?.resize(targetSize: CGSize(square: 56)) {
                vc.avatarImageView.image = image
            } else {
                vc.avatarImageView.image = UIImageView.getDefaultAvatar(
                    for: self.nickname,
                    owner: self.owner,
                    size: 56
                )
            }
        }
        
        self.navigationController?.pushViewController(vc, animated: true)
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
        
        
        if leftMenuDelegate == nil {
            let chatVc = ChatViewController()
            chatVc.owner = self.owner
            chatVc.jid = self.jid
            chatVc.conversationType = .group
            chatVc.activateSearchModeFromExternalRoute()
            navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
            navigationController?.navigationBar.shadowImage = nil
            if let rootVc = navigationController?.viewControllers.first {
                navigationController?.setViewControllers([rootVc, chatVc], animated: true)
            } else {
                navigationController?.pushViewController(chatVc, animated: true)
            }
        } else {
            self.leftMenuDelegate?.openChatlistWithChat(owner: self.owner, jid: self.jid, conversationType: .group, configure: { chatVc in
                chatVc?.activateSearchModeFromExternalRoute()
            })
            self.dismiss(animated: true)
        }
        
    }
    
    @objc
    internal func groupchatInfo(_ sender: UIBarButtonItem) {
        showSettings()
    }
    
    func onChangeAvatar() {
        let groupchatItems = [
            ActionSheetPresenter.Item(destructive: false, title: "Use emoji".localizeString(id: "account_emoji_profile_image_button", arguments: []), value: "emoji"),
            ActionSheetPresenter.Item(destructive: false, title: "Open gallery".localizeString(id: "account_open_gallery", arguments: []), value: "gallery"),
            ActionSheetPresenter.Item(destructive: false, title: "Open camera".localizeString(id: "account_open_camera", arguments: []), value: "camera")
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
        self.navigationController?.pushViewController(vc, animated: true)
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
    
    func onUpdateAvatar(_ image: UIImage?) {
        guard let image,
              let account = AccountManager.shared.find(for: owner) else { return }
        view.makeToastActivity(.center)
        account.avatarUploader.setGroupAvatar(
            groupchat: jid,
            image: image,
            successCallback: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.view.hideToastActivity()
                    self.headerView.imageButton.setImage(
                        image.resize(targetSize: CGSize(square: 128)),
                        for: .normal
                    )
                }
            },
            failureCallback: { [weak self] _, error in
                DispatchQueue.main.async {
                    self?.onUpdateAvatarFailure(error)
                }
            },
            queuedCallback: { [weak self] in
                DispatchQueue.main.async {
                    self?.view.hideToastActivity()
                    self?.headerView.imageButton.setImage(
                        image.resize(targetSize: CGSize(square: 128)),
                        for: .normal
                    )
                }
            }
        )
    }

    private func onUpdateAvatarFailure(_ error: String) {
        view.hideToastActivity()
        ErrorMessagePresenter().present(
            in: self,
            message: error.isNotEmpty
                ? error
                : "Internal server error".localizeString(id: "error_internal_server", arguments: []),
            animated: true,
            completion: nil
        )
    }
}

extension GroupchatInfoViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        self.onUpdateAvatar(image)
    }
}
