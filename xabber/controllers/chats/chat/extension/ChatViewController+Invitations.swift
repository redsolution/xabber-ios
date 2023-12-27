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
import Toast_Swift
import CocoaLumberjack


extension ChatViewController {
    
    private final func onInviteActionSelected() {
        DispatchQueue.main.async {
            self.view.makeToastActivity(.center)
        }
    }
    
    private final func onInviteCallbackCalled() {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
    }
    
    internal func didReceiveInvite(_ primary: String) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [self.jid, self.owner].prp()),
               instance.subscribtion == .both {
                try realm.write {
                    realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary)?.isProcessed = true
                }
                return
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        
//        DispatchQueue.main.async {
            self.showInviteActionsMenu()
//        }
    }
    
    private final func showInviteActionsMenu() {
        let incognitoMessage: String = "You are invited to join this incognito group"
            .localizeString(id: "incognito_group_invitation", arguments: [])
        let publicMessage: String = "You are invited to join this public group"
            .localizeString(id: "public_group_invitation", arguments: [])
        let privateChatMessage: String = "You are invited to join private chat"
            .localizeString(id: "private_chat_invitation", arguments: [])
        var message: String = publicMessage
        let values: [ActionSheetPresenter.Item] = [
            ActionSheetPresenter.Item(destructive: false, title: self.entity == .privateChat ? "Join chat".localizeString(id: "join_chat", arguments: []) : "Join group".localizeString(id: "join_group", arguments: []), value: "accept"),
            ActionSheetPresenter.Item(destructive: false,
                                      title: "Decline".localizeString(id: "decline", arguments: []),
                                      value: "decline"),
            ActionSheetPresenter.Item(destructive: true,
                                      title: "Block".localizeString(id: "contact_bar_block", arguments: []),
                                      value: "block"),
        ]
        
        switch self.entity {
        case .groupchat: message = publicMessage
        case .incognitoChat: message = incognitoMessage
        case .privateChat: message = privateChatMessage
        default: break
        }
        
        self.view.tintAdjustmentMode = .normal
//        UIView.performWithoutAnimation {
//            self.xabberInputBar.alpha = true
//            self.xabberInputBar.layoutIfNeeded()
//        }
        let presenter = ActionSheetPresenter()
        presenter.completion = self.onCompleteInvite
//        self.initialtp[
//        additionalTopInset = 274
        self.messageCollectionViewLastKBPosition = 224
//        self.messageCollectionViewTopInset = self.requiredInitialScrollViewBottomInset()
        presenter.present(
            in: self,
            title: nil,
            message: message,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: values,
            animated: false,
            cancelAction: onCancelInvite) { (value) in
            self.onInviteActionSelected()
            switch value {
            case "accept":
                self.onAcceptInvite()
            case "decline":
                self.onDeclineInvite()
            case "block":
                self.onBlockInvite()
            default:
                break
            }
            self.becomeFirstResponder()
            UIView.animate(withDuration: 0.2) {
                self.messageCollectionViewLastKBPosition = 0
//                self.messageCollectionViewTopInset = self.requiredInitialScrollViewBottomInset()
            }
        }
    }
    
    private final func onAcceptInvite() {
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.join(stream, uiConnection: true, groupchat: self.jid) { (error) in
                self.onReceiveAcceptInviteCallback(error: error)
            }
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.join(stream, uiConnection: false, groupchat: self.jid) { (error) in
                    self.onReceiveAcceptInviteCallback(error: error)
                }
            })
        })
    }
    
    private final func onReceiveAcceptInviteCallback(error: String?) {
        self.onInviteCallbackCalled()
        if let error = error {
            var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
            switch error {
            case "conflict":
                message = "Conflict".localizeString(id: "message_manager_error_conflict", arguments: [])
            case "not-allowed":
                message = "Not allowed".localizeString(id: "message_manager_error_unallowed", arguments: [])
            case "fail":
                message = "Network unreachable".localizeString(id: "message_manager_error_unreachable_network", arguments: [])
            case "timeout":
                message = "Request timeout".localizeString(id: "message_manager_errpr_request_timeout", arguments: [])
            default: break
            }
            DispatchQueue.main.async {
                ErrorMessagePresenter().present(
                    in: self,
                    alert: true,
                    message: ["Error".localizeString(id: "error", arguments: []), message].joined(separator: ": "),
                    animated: true
                ) {
                    self.navigationController?.popViewController(animated: true)
                }
            }

        } else {
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm
                        .objects(GroupchatInvitesStorageItem.self)
                        .filter("owner == %@ AND groupchat == %@", self.owner, self.jid)
                        .first {
                        try realm.write {
                            instance.isRead = true
                            instance.isProcessed = true
                        }
                    }
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }
        }
    }
    
    private final func onDeclineInvite() {
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.decline(stream, groupchat: self.jid) { (error) in
                self.onReceiveDeclineInviteCallback(error: error)
            }
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.decline(stream, groupchat: self.jid) { (error) in
                    self.onReceiveDeclineInviteCallback(error: error)
                }
            })
        })
    }
    
    private final func onReceiveDeclineInviteCallback(error: String?, blockCallback: Bool = false) {
        self.onInviteCallbackCalled()
        if let error = error {
            var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
            switch error {
            case "conflict":
                message = "Conflict".localizeString(id: "message_manager_error_conflict", arguments: [])
            case "not-allowed":
                message = "Not allowed".localizeString(id: "message_manager_error_unallowed", arguments: [])
            case "fail":
                message = "Network unreachable".localizeString(id: "message_manager_error_unreachable_network", arguments: [])
            case "timeout":
                message = "Request timeout".localizeString(id: "message_manager_errpr_request_timeout", arguments: [])
            default: break
            }
            DispatchQueue.main.async {
                ErrorMessagePresenter().present(
                    in: self,
                    alert: true,
                    message: ["Error".localizeString(id: "error", arguments: []), message].joined(separator: ": "),
                    animated: true
                ) {
                    self.navigationController?.popViewController(animated: true)
                }
            }

        } else {
            if blockCallback {
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.blocked?.blockContact(stream, jid: self.jid)
                }, fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.blocked.blockContact(stream, jid: self.jid)
                    })
                })

            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let realm = try  WRealm.safe()
                    if let instance = realm
                        .objects(GroupchatInvitesStorageItem.self)
                        .filter("owner == %@ AND groupchat == %@", self.owner, self.jid)
                        .first {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                    if let instance = realm
                        .objects(LastChatsStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                        .first {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                    if let instance = realm
                        .objects(RosterStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                        .first {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                    if let instance = realm
                        .objects(GroupChatStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                        .first {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                    let resources = realm
                        .objects(ResourceStorageItem.self)
                        .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                    try realm.write {
                        realm.delete(resources)
                    }
                } catch {
                    DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.navigationController?.popToRootViewController(animated: true)
            }
        }
    }
    
    private final func onBlockInvite() {
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.decline(stream, groupchat: self.jid) { (error) in
                self.onReceiveDeclineInviteCallback(error: error, blockCallback: true)
            }
        }, fail: {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.decline(stream, groupchat: self.jid) { (error) in
                    self.onReceiveDeclineInviteCallback(error: error, blockCallback: true)
                }
            })
        })
    }
    
    private final func onCancelInvite() {
        UIView.performWithoutAnimation {
//            self.messageCollectionViewLastKBPosition = 0
//            self.messageCollectionViewTopInset = self.requiredInitialScrollViewBottomInset()
        }
        self.navigationController?.popViewController(animated: true)
    }
    
    private final func onCompleteInvite() {
        
    }
    
}
