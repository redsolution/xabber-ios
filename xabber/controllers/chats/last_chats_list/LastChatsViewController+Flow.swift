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
import YubiKit

extension LastChatsViewController {
    
    internal final func showAddDialog() {
        let vc = NewEntityViewController()
        vc.addContactDelegate = self
        vc.delegate = self
        self.navigationController?.pushViewController(vc, animated: true)
//        let nvc = UINavigationController(rootViewController: vc)
//        nvc.modalPresentationStyle = .fullScreen
//        nvc.modalTransitionStyle = .coverVertical
//        self.definesPresentationContext = true
//        self.present(nvc, animated: true, completion: nil)
    }
    
    internal final func showRegisterYubikeyDialog() {
        if SignatureManager.shared.certificate != nil {
            let vc = YubikeySetupViewController()
            vc.isFromOnboarding = false
            vc.isModal = true
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            SignatureManager.shared.delegate = self
            FeedbackManager.shared.tap()
            if #available(iOS 13.0, *) {
                if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                    YubiKitExternalLocalization.nfcScanAlertMessage = "Register Yubikey for account"
                    YubiKitManager.shared.startNFCConnection()
                    YubiKitManager.shared.delegate = SignatureManager.shared
                    SignatureManager.shared.currentAction = .certificate
                }
            }
        }
    }
    
    @objc
    internal func onAddContact() {
        showAddDialog()
    }
    
    @objc
    internal func onRegisterYubikey() {
        showRegisterYubikeyDialog()
    }
    
    @objc
    internal func onReadAllMessages(_ sender: UIButton) {
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(LastChatsStorageItem.self)
                .filter("isArchived == false AND unread > 0 AND owner IN %@", Array(self.enabledAccounts.value))
                .sorted(byKeyPath: "messageDate", ascending: false)

            let unreadLastChatsArray = collection.toArray()
            try realm.write {
                collection.forEach { $0.unread = 0 }
            }
            self.enabledAccounts.value.forEach {
                AccountManager.shared.find(for: $0)?.unsafeAction({ user, stream in
                    user.messages.readAllMessages()
                })
            }
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        self.filter.accept(.chats)
//        DispatchQueue.main.async {
//            
//            getAppTabBar()?.tabBar.items?.first?.image = #imageLiteral(resourceName: "chat-outline")
//            getAppTabBar()?.tabBar.items?.first?.selectedImage = #imageLiteral(resourceName: "chat-outline")
//            getAppTabBar()?.tabBar.items?.first?.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
//        }
    }
    
    internal final func pinChat(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        
        func fallback() {
            DispatchQueue.main.async {
                self.view.makeToast("Your server doesn`t support pinned chats. Please use Clandestino server."
                                        .localizeString(id: "server_doesnt_support_pinned_chats", arguments: []))
            }
        }
//        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
//            if !(session.sync?.pinChat(stream, jid: jid, conversationType: conversationType) ?? false) {
//                fallback()
//            }
//        } fail: {
            AccountManager.shared.find(for: owner)?.action({ user, stream in
                if !user.syncManager.pinChat(stream, jid: jid, conversationType: conversationType) {
                    fallback()
                }
            })
//        }
    }
    
    internal func onGroupchatInfo(_ jid: String, owner: String) {
        XMPPUIActionManager.shared.open(owner: owner)
        let vc = GroupchatInfoViewController()
        vc.owner = owner
        vc.jid = jid
        self.title = " "
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.layoutIfNeeded()
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func onContactInfo(_ jid: String, owner: String) {
        XMPPUIActionManager.shared.open(owner: owner)
        let vc = ContactInfoViewController()
        vc.owner = owner
        vc.jid = jid
        self.title = " "
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.layoutIfNeeded()
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func onArchive(_ jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType, reverse: Bool) {
        do {
            let realm = try  WRealm.safe()
            guard let instance = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: conversationType)
            ) else {
                return
            }
            let value = instance.isArchived
            try realm.write {
                instance.isArchived = !reverse
            }
            let conversationType = instance.conversationType
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
//            XMPPUIActionManager.shared.open(owner: owner)
//            XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
//                _ = session.sync?.update(stream, jid: jid, conversationType: conversationType, status: value ? .active : .archived)
//            } fail: {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    _ = user.syncManager.update(stream, jid: jid, conversationType: conversationType, status: value ? .active : .archived)
                })
//            }

        } catch {
            DDLogDebug("cant change archive state for \(jid)")
        }
    }
    
    internal func onDelete(_ jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType, displayName: String) {
        
        YesNoPresenter().present(
            in: self,
            style: .actionSheet,
            title: "Delete chat",
            message: "All messages will be deleted",
            yesText: "Delete",
            dangerYes: true,
            noText: "Cancel",
            animated: true) { value in
                if value {
//                    XMPPUIActionManager.shared.performRequest(owner: owner) { stream, user in
//                        _ = user.sync?.update(
//                            stream,
//                            jid: jid,
//                            conversationType: conversationType,
//                            status: .deleted
//                        )
//                        user.retract?.deleteAllMessages(
//                            stream,
//                            jid: jid,
//                            conversationType: conversationType,
//                            callback: nil
//                        )
//                    } fail: {
                        AccountManager.shared.find(for: owner)?.action({ user, stream in
                            _ = user.syncManager.update(
                                stream,
                                jid: jid,
                                conversationType: conversationType,
                                status: .deleted
                            )
                            user.msgDeleteManager.deleteAllMessages(
                                stream,
                                jid: jid,
                                conversationType: conversationType,
                                callback: nil
                            )
                        })
//                    }
                    do {
                        let realm = try  WRealm.safe()
                        try realm.write {
                            if let instance = realm.object(
                                ofType: LastChatsStorageItem.self,
                                forPrimaryKey: LastChatsStorageItem.genPrimary(
                                    jid: jid,
                                    owner: owner,
                                    conversationType: conversationType
                                )
                            ) {
                                realm.delete(instance)
                            }
                        }
                        self.canUpdateDataset = true
                        self.runDatasetUpdateTask()
                    } catch {
                        DDLogDebug("ClientSynchronizationManager: \(#function). \(error.localizedDescription)")
                    }

                }
            }
    }
    
    internal func updateArchivedSectionTitle() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let inactiveColor: UIColor
        if #available(iOS 13.0, *) {
            inactiveColor = .secondaryLabel
        } else {
            inactiveColor = UIColor(red:0.56, green:0.56, blue:0.58, alpha:1)
        }
        let activeColor: UIColor
        if #available(iOS 13.0, *) {
            activeColor = .label
        } else {
            activeColor = .darkText
        }
        
        archivedChats?.enumerated().forEach {
            (offset, item) in
            let text: String
            if offset == (archivedChats?.count ?? 0) - 1 {
                text = (item.rosterItem?.displayName ?? item.jid)
            } else {
                text = (item.rosterItem?.displayName ?? item.jid) + ", "
            }
            out.append(NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key.foregroundColor: item.unread == 0 ? inactiveColor: activeColor,
                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)
                ]
            ))
        }
        
        let textRange = NSRange(location: 0, length: (out.string as NSString).length)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.43
        paragraphStyle.lineBreakMode = .byWordWrapping
//        paragraphStyle.
        out.addAttribute(NSAttributedString.Key.paragraphStyle, value:paragraphStyle, range: textRange)
        out.addAttribute(NSAttributedString.Key.kern, value: -0.22, range: textRange)
        
        return out
    }
    
    internal func onChangeNotifications(jid: String, owner: String, isMuted: Bool, conversationType: ClientSynchronizationManager.ConversationType) {
        XMPPUIActionManager.shared.open(owner: owner)
        if isMuted {
//            XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
//                _ = session.sync?.update(stream, jid: jid, conversationType: conversationType, mute: nil)
//            } fail: {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    _ = user.syncManager.update(stream, jid: jid, conversationType: conversationType, mute: nil)
                })
//            }
        } else {
            let muteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 15 minutes"
                                            .localizeString(id: "mute_15_min", arguments: []),
                                          value: "mute_15_min"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 1 hour"
                                            .localizeString(id: "mute_1_hour", arguments: []),
                                          value: "mute_1_hour"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 2 hours"
                                            .localizeString(id: "mute_2_hours", arguments: []),
                                          value: "mute_2_hours"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute for 1 day"
                                            .localizeString(id: "mute_1_day", arguments: []),
                                          value: "mute_1_day"),
                ActionSheetPresenter.Item(destructive: false, title: "Mute forever"
                                            .localizeString(id: "mute_forever", arguments: []),
                                          value: "mute_forever"),
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
//                XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
//                    _ = session.sync?.update(stream, jid: jid, conversationType: conversationType, mute: expiredAt)
//                } fail: {
                    AccountManager.shared.find(for: owner)?.action({ user, stream in
                        _ = user.syncManager.update(stream, jid: jid, conversationType: conversationType, mute: expiredAt)
                    })
//                }
            }
        }
    }
    
}


extension LastChatsViewController: NewEntityViewControllerDelegate {
    func openChat(_ jid: String, owner: String) {
        openChat(owner: owner, jid: jid, conversationType: .omemo)
    }
}
