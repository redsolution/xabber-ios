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
import Toast_Swift
import CocoaLumberjack

extension ContactInfoViewController: InfoScreenHeaderButtonDelegate {
    func shouldUpdateAvatar() -> UIImage? {
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
//            user.PEPAvatars.refreshAvatar(jid: self.jid)
        })
        let conf = LetterAvatarBuilderConfiguration()
        conf.username = self.nickname.uppercased()
        conf.size = DefaultAvatarManager.defaultSize
        conf.backgroundColors = [AccountColorManager.shared.palette(for: owner).tint600]
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
//        print(#function)
        VoIPManager.shared.startCall(owner: self.owner, jid: self.jid)
    }
    
    func onThirdButtonPressed() {
        onChangeNotifications()
    }
    
    func onFourthButtonPressed() {
        onBlock()
    }
    
    func onImageButtonPressed() {
        print(#function)
    }
    
    func onTitleButtonPressed() {
        print(#function)
    }
    
    @objc
    internal func showFullVCard(_ sender: AnyObject) {
        let vc = vCardInfoViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func editCircles() {
        let vc = EditContactViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        vc.isCircleSelectView = true
        let nvc = UINavigationController(rootViewController: vc)
        nvc.modalPresentationStyle = .fullScreen
        nvc.modalTransitionStyle = .coverVertical
        self.definesPresentationContext = true
        self.present(nvc, animated: true, completion: nil)
    }
    
    func onQRCode() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: RosterStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.displayName ?? jid
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
    
    internal func openChat() {
        let chatVc = ChatViewController()
        chatVc.owner = self.owner
        chatVc.jid = self.jid
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        if let rootVc = navigationController?.viewControllers.first {
            navigationController?.setViewControllers([rootVc, chatVc], animated: true)
        } else {
            navigationController?.pushViewController(chatVc, animated: true)
        }
    }
    
    internal func onChangeNotifications() {
        if isMuted {
//            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                _ = session.sync?.update(stream, jid: self.jid, conversationType: .omemo, mute: nil)
//            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    _ = user.syncManager.update(stream, jid: self.jid, conversationType: .omemo, mute: nil)
                })
//            }
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
//                XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                    _ = session.sync?.update(stream, jid: self.jid, conversationType: .omemo, mute: expiredAt)
//                } fail: {
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        _ = user.syncManager.update(stream, jid: self.jid, conversationType: .omemo, mute: expiredAt)
                    })
//                }
            }
        }
    }
    
    internal func onBlock() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: RosterStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.displayName ?? jid
            let unblockItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Unblock".localizeString(id: "contact_bar_unblock", arguments: []), value: "unblock")
            ]
            let blockItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Block".localizeString(id: "contact_bar_block", arguments: []), value: "block"),
                ActionSheetPresenter.Item(destructive: true, title: "Block and delete".localizeString(id: "contact_block_and_delete", arguments: []), value: "block_delete"),
            ]
            ActionSheetPresenter().present(
                in: self,
                title: isBlocked ? "Unblock contact".localizeString(id: "chat_settings__button_unblock_contact", arguments: []) : "Block contact".localizeString(id: "contact_block", arguments: []),
                message: isBlocked ? "Do you really want to unblock contact \(displayedName)?".localizeString(id: "contact_unblock_confirmation", arguments: ["\(displayedName)"]) : "Do you really want to block contact \(displayedName)?".localizeString(id: "contact_block_confirmation", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: isBlocked ? unblockItems : blockItems,
                animated: true
            ) { value in
                switch value {
                case "unblock":
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.blocked.unblockContact(stream, jid: self.jid)
                    })
                case "block":
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.blocked.blockContact(stream, jid: self.jid)
                    })
                case "block_delete":
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.presences.unsubscribe(stream, jid: self.jid)
                        user.presences.unsubscribed(stream, jid: self.jid)
                        user.roster.removeContact(stream, jid: self.jid)
                        user.blocked.blockContact(stream, jid: self.jid)
                    })
                    DispatchQueue.main.async {
                        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                        self.navigationController?.navigationBar.shadowImage = nil
                        self.navigationController?.popToRootViewController(animated: true)
                    }
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func onDelete() {
        do {
            let realm = try WRealm.safe()
            let displayedName = realm.object(ofType: RosterStorageItem.self,
                                             forPrimaryKey: [jid, owner].prp())?.displayName ?? jid
            let deleteItems: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Delete".localizeString(id: "contact_delete", arguments: []), value: "delete"),
                ActionSheetPresenter.Item(destructive: true, title: "Delete contact and clear history".localizeString(id: "delete_contact_and_clear_history", arguments: []), value: "delete_clear")
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Delete contact".localizeString(id: "contact_delete_full", arguments: []),
                message: "Do you really want to delete contact \(displayedName)?".localizeString(id: "contact_delete_confirm_short", arguments: ["\(displayedName)"]),
                cancel: "Cancel".localizeString(id: "cancel", arguments: []),
                values: deleteItems,
                animated: true
            ) { value in
                DispatchQueue.main.async {
                    self.view.makeToastActivity(.center)
                }
                switch value {
                case "delete":
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.roster.removeContact(stream, jid: self.jid) { (jid, error, success) in
                            DispatchQueue.main.async {
                                self.view.hideToastActivity()
                            }
                            if success {
                                DispatchQueue.main.async {
                                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                                    self.navigationController?.navigationBar.shadowImage = nil
                                    self.navigationController?.popToRootViewController(animated: true)
                                }
                            } else {
                                var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                                if let error = error {
                                    switch error {
                                    case "item-not-found":
                                        message = "JID \(self.jid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.jid)"])
                                    case "forbidden":
                                        message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                                    case "not-acceptable":
                                        message = "Invalid circles list".localizeString(id: "invalid_circles_list", arguments: [])
                                    case "remote-server-not-found":
                                        message = "Remote server not found".localizeString(id: "error_server_not_found", arguments: [])
                                    default: break
                                    }
                                }
                                DispatchQueue.main.async {
                                    self.view.makeToast(message)
                                }
                            }
                        }
                    })
                case "delete_clear":
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        _ = user.syncManager.update(stream, jid: self.jid, conversationType: .omemo, status: .deleted)
                        user.roster.removeContact(stream, jid: self.jid) { (jid, error, success) in
                            DispatchQueue.main.async {
                                self.view.hideToastActivity()
                            }
                            if success {
                                DispatchQueue.main.async {
                                    self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
                                    self.navigationController?.navigationBar.shadowImage = nil
                                    self.navigationController?.popToRootViewController(animated: true)
                                }
                            } else {
                                var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                                if let error = error {
                                    switch error {
                                    case "item-not-found":
                                        message = "JID \(self.jid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.jid)"])
                                    case "forbidden":
                                        message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                                    case "not-acceptable":
                                        message = "Invalid circles list".localizeString(id: "invalid_circles_list", arguments: [])
                                    case "remote-server-not-found":
                                        message = "Remote server not found".localizeString(id: "error_server_not_found", arguments: [])
                                    default: break
                                    }
                                }
                                DispatchQueue.main.async {
                                    self.view.makeToast(message)
                                }
                            }
                        }
                    })
                default: break
                }
            }
        } catch {
            DDLogDebug("ContactInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    internal func onEditContact(_ sender: UIBarButtonItem) {
        let vc = EditContactViewController()
        vc.owner = self.owner
        vc.jid = self.jid
        self.navigationController?.pushViewController(vc, animated: true)
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
            let nvc = UINavigationController(rootViewController: vc)
            nvc.modalPresentationStyle = .fullScreen
            nvc.modalTransitionStyle = .coverVertical
            self.definesPresentationContext = true
            self.present(nvc, animated: true, completion: nil)
        } catch {
            DDLogDebug("GroupchatInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    func showFingerprints() {
        let vc = TrustedDevicesViewController()
        vc.jid = self.jid
        vc.owner = self.owner
        self.navigationController?.pushViewController(vc, animated: true)
    }
}
