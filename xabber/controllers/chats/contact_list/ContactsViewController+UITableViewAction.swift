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
import Realm
import RealmSwift
import CocoaLumberjack

extension ContactsViewController {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        let section = indexPath.section
        let item = self.datasource[section][index]
        
        if AccountManager.shared.connectingUsers.value.isEmpty {
            
            switch self.category {
                case "all", "online", "subscribtions", "requests":
                    let deleteAction = UIContextualAction(style: .normal,
                                                       title: "Delete contact".localizeString(id: "remove_contact", arguments: [])) {
                        action, view, handler in
                        let jid = item.jid
                        let owner = item.owner
                        self.deleteContact(jid: jid, owner: owner)
                        handler(true)
                    }
                    deleteAction.image = imageLiteral( "trash")?.withRenderingMode(.alwaysTemplate)
                    deleteAction.backgroundColor = .systemRed
                    
                    let blockAction = UIContextualAction(style: .normal,
                                                         title: "Block contact".localizeString(id: "block_contact", arguments: [])) {
                          action, view, handler in
                          let jid = item.jid
                          let owner = item.owner
                          self.blockContact(jid: jid, owner: owner)
                          handler(true)
                      }
                    blockAction.image = imageLiteral( "hand.raised")?.withRenderingMode(.alwaysTemplate)
                    blockAction.backgroundColor = .systemRed
                      
                    return UISwipeActionsConfiguration(actions: [deleteAction, blockAction])
                case "public", "incognito", "private":
                    let action = UIContextualAction(style: .normal,
                                                       title: "Leave".localizeString(id: "groupchat_leave", arguments: [])) {
                        action, view, handler in
                        let jid = item.jid
                        let owner = item.owner
                        self.leaveGroup(jid: jid, owner: owner)
                        handler(true)
                    }
                    action.image = imageLiteral( "figure.run")?.withRenderingMode(.alwaysTemplate)
                    action.backgroundColor = .systemRed
                    return UISwipeActionsConfiguration(actions: [action])
                case "invitations":
                    let deleteAction = UIContextualAction(style: .normal,
                                                       title: "Decline".localizeString(id: "decline_invite", arguments: [])) {
                        action, view, handler in
                        let jid = item.jid
                        let owner = item.owner
                        self.cancelInvite(jid: jid, owner: owner)
                        handler(true)
                    }
                    deleteAction.image = imageLiteral( "trash")?.withRenderingMode(.alwaysTemplate)
                    deleteAction.backgroundColor = .systemRed
                    
                    let blockAction = UIContextualAction(style: .normal,
                                                         title: "Block group".localizeString(id: "block_group", arguments: [])) {
                          action, view, handler in
                          let jid = item.jid
                          let owner = item.owner
                          self.blockContact(jid: jid, owner: owner)
                          handler(true)
                      }
                    blockAction.image = imageLiteral( "hand.raised")?.withRenderingMode(.alwaysTemplate)
                    blockAction.backgroundColor = .systemRed
                      
                    return UISwipeActionsConfiguration(actions: [deleteAction, blockAction])
                default:
                    return nil
            }
        } else {
            return nil
        }
    }
    
    private func deleteContact(jid: String, owner: String) {
        YesNoPresenter().present(
            in: self,
            title: nil,
            message: "Do you really want to delete contact".localizeString(id: "contact_delete_confirm", arguments: [jid, owner]),
            yesText: "Delete".localizeString(id: "delete", arguments: []),
            dangerYes: true,
            noText: "Cancel".localizeString(id: "cancel", arguments: []),
            animated: true) { value in
            if value {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.presences.unsubscribe(stream, jid: jid)
                    user.presences.unsubscribed(stream, jid: jid)
                    user.roster.removeContact(stream, jid: jid) { jid, error, _ in
                        if error != nil {
                            DispatchQueue.main.async {
                                ToastPresenter().presentError(message: "Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                                self.preprocessDataset(changeCategory: false)
                            }
                        }
                    }
                }
            }
        }
        
    }
    
    private func blockContact(jid: String, owner: String) {
        YesNoPresenter().present(
            in: self,
            title: nil,
            message: "Do you really want to block contact".localizeString(id: "contact_block", arguments: []),
            yesText: "Block".localizeString(id: "block", arguments: []),
            dangerYes: true,
            noText: "Cancel".localizeString(id: "cancel", arguments: []),
            animated: true) { value in
            if value {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.blocked.blockContact(stream, jid: jid)
                    DispatchQueue.main.async {
                        ToastPresenter().presentError(message: "Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                        self.preprocessDataset(changeCategory: false)
                    }
                }
            }
        }
        
    }
    
    private func leaveGroup(jid: String, owner: String) {
        YesNoPresenter().present(
            in: self,
            title: nil,
            message: "Do you really want to leave groupchat \(jid)",
            yesText: "Leave".localizeString(id: "groupchat_bar_leave", arguments: []),
            dangerYes: true,
            noText: "Cancel".localizeString(id: "cancel", arguments: []),
            animated: true) { value in
            if value {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.groupchats.leave(stream, groupchat: jid) { _ in
                        DispatchQueue.main.async {
                            ToastPresenter().presentError(message: "Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                            self.preprocessDataset(changeCategory: false)
                        }
                    }
                    user.groupchats.afterLeave(groupchat: jid)
                    DispatchQueue.main.async {
                        ToastPresenter().presentError(message: "Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                        self.preprocessDataset(changeCategory: false)
                    }
                }
            }
        }
        
    }
    
    private func cancelInvite(jid: String, owner: String) {
        YesNoPresenter().present(
            in: self,
            title: nil,
            message: "Do you really want to delete invite to groupchat \(jid)",
            yesText: "Delete".localizeString(id: "delete", arguments: []),
            dangerYes: true,
            noText: "Cancel".localizeString(id: "cancel", arguments: []),
            animated: true) { value in
            if value {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.groupchats.decline(stream, groupchat: jid) { error in
                        do {
                            let realm = try WRealm.safe()
                            let invites = realm.objects(GroupchatInvitesStorageItem.self).filter("groupchat == %@ AND owner == %@", jid, owner)
                            try realm.write {
                                invites.forEach { realm.delete($0) }
                            }
                        } catch {
                            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                        }
                        DispatchQueue.main.async {
                            ToastPresenter().presentError(message: "Unexpected error".localizeString(id: "unexpected_error", arguments: []))
                            self.preprocessDataset(changeCategory: false)
                        }
                    }
                }
            }
        }
        
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        let section = indexPath.section
        let item = self.datasource[section][index]
        if AccountManager.shared.connectingUsers.value.isEmpty {
            let action = UIContextualAction(style: .normal,
                                               title: "Chat".localizeString(id: "chat_viewer", arguments: [])) {
                action, view, handler in
                let jid = item.jid
                let owner = item.owner
                let conversationType = item.conversationType
                self.showChat(jid: jid, owner: owner, conversationType: conversationType)
                handler(true)
            }
            action.image = imageLiteral( "bubble")?.withRenderingMode(.alwaysTemplate)
            action.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [action])
        } else {
            return nil
        }
    }
    
    private func showChat(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        if conversationType == .omemo {
            AccountManager.shared.find(for: owner)?.omemo.initChat(jid: jid)
        }
        if leftMenuDelegate == nil {
            let chatVc = ChatViewController()
            chatVc.owner = owner
            chatVc.jid = jid
            chatVc.conversationType = conversationType
            
            showDetail(chatVc, currentVc: self)
        } else {
            self.leftMenuDelegate?.openChatlistWithChat(owner: owner, jid: jid, conversationType: conversationType, configure: nil)
            
        }
    }
}
