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
import CocoaLumberjack

extension ContactsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func getEmptyStateString() -> String? {
        if let category = self.category {
            switch category {
                case "all":
                    if self.filteredGroups.isNotEmpty {
                        let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                        return "No contacts found for \(groupsString)"
                    }
                    return "No contacts found"
                case "online":
                    if self.filteredGroups.isNotEmpty {
                        let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                        return "No online contacts found for \(groupsString)"
                    }
                    return "No contacts online"
                case "subscriptions":
                    return "No contact requests"
                case "requests":
                    return "No outgoing contact requests"
                case "public":
                    if self.filteredGroups.isNotEmpty {
                        let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                        return "No public groups found for \(groupsString)"
                    }
                    return "No public groups found"
                case "incognito":
                    if self.filteredGroups.isNotEmpty {
                        let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                        return "No incognito groups found for \(groupsString)"
                    }
                    return "No incognito groups found"
                case "private":
                    if self.filteredGroups.isNotEmpty {
                        let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                        return "No private chats found for \(groupsString)"
                    }
                    return "No private chats found"
                case "invitations":
                    return "No invitations found"
                default:
                    if isGroup {
                        if self.filteredGroups.isNotEmpty {
                            let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                            return "No groups found for \(groupsString)"
                        }
                        return "No groups found"
                    } else {
                        if self.filteredGroups.isNotEmpty {
                            let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                            return "No contacts found for \(groupsString)"
                        }
                        return "No contacts found"
                    }
            }
        } else {
            if isGroup {
                if self.filteredGroups.isNotEmpty {
                    let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                    return "No groups found for \(groupsString)"
                }
                return "No groups found"
            } else {
                if self.filteredGroups.isNotEmpty {
                    let groupsString = self.filteredGroups.sorted().joined(separator: ", ")
                    return "No contacts found for \(groupsString)"
                }
                return "No contacts found"
            }
        }
    }
    
    func getFooterString() -> String? {
        guard let lastDatasource = self.datasource.last, lastDatasource.isNotEmpty, lastDatasource.first?.isHeader == false else {
            return nil
        }
        let count = lastDatasource.count
        let onlineCount = lastDatasource.filter({ $0.status != .offline }).count
        let commonCountPlural = count == 1
        var groupsList: String = ""
        var footer: String = ""
        if self.filteredGroups.isNotEmpty {
            let groupsSorted = self.filteredGroups.sorted()
            if groupsSorted.count == 1 {
                groupsList = "in circle \(groupsSorted[0])"
            } else {
                let groupsString = groupsSorted.joined(separator: ", ")
                groupsList = "in circles \(groupsString)"
            }
        }
        if self.showOffline == false {
            footer = "\(onlineCount) online"
        } else if let category = self.category {
            switch category {
                case "all":
                    footer = "\(count) \(commonCountPlural ? "contact" : "contacts")"
                case "online":
                    footer = "\(onlineCount) online \(commonCountPlural ? "contact" : "contacts")"
                case "subscriptions":
                    footer = "\(count) \(commonCountPlural ? "contact request" : "contact requests")"
                case "requests":
                    footer = "\(count) \(commonCountPlural ? "outgoing request" : "outgoing requests")"
                case "public":
                    footer = "\(count) \(commonCountPlural ? "public group" : "public groups")"
                case "incognito":
                    footer = "\(count) \(commonCountPlural ? "incognito group" : "incognito groups")"
                case "private":
                    footer = "\(count) \(commonCountPlural ? "private chat" : "private chats")"
                case "invitations":
                    footer = "\(count) \(commonCountPlural ? "invitation" : "invitations")"
                default:
                    if isGroup {
                        footer = "\(count) \(commonCountPlural ? "group" : "groups")"
                    } else {
                        footer = "\(count) \(commonCountPlural ? "contact" : "contacts") \(onlineCount) online"
                    }
            }
        } else {
            if isGroup {
                footer = "\(count) \(commonCountPlural ? "group" : "groups")"
            } else {
                footer = "\(count) \(commonCountPlural ? "contact" : "contacts")"
            }
        }
        return "\(footer) \(groupsList)"
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
//        if self.datasource.count == 1, self.datasource[0].count == 0 {
//            if section == 0 {
//                return getEmptyStateString()
//            }
//        }
//        if self.datasource.count == 2, self.datasource[1].count == 0 {
//            if section == 1 {
//                return getEmptyStateString()
//            }
//        }
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == self.datasource.count - 1 {
            return getFooterString()
        }
        return nil
    }
    
//    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
////        if hasContactsRequestSection {
////            return "Incoming contact requests"
////        }
//        return nil
//    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemHeaderTableCell.cellName, for: indexPath) as? MenuItemHeaderTableCell else {
                fatalError()
            }
            
            cell.configure(title: item.title, subtitle: item.subtitle, icon: item.icon, color: .tintColor)

            cell.selectionStyle = .none

            return cell
        }
        if item.isSubscribtionRequest {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: AddContactCell.cellName,
                                                           for: indexPath) as? AddContactCell else {
                fatalError()
            }
            
            cell.configure(
                title: item.title,
                subtitle: item.subtitle,
                jid: item.jid,
                owner: item.owner,
                showAvatar: true,
                avatarUrl: item.avatarUrl
            )
            cell.cellDelegate = self
            cell.setMask()
            cell.selectionStyle = .none
            
            return cell
        } else if item.isContactRequest {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: RequestContactCell.cellName,
                                                           for: indexPath) as? RequestContactCell else {
                fatalError()
            }
            
            cell.configure(
                title: item.title,
                subtitle: item.subtitle,
                jid: item.jid,
                owner: item.owner,
                showAvatar: true,
                avatarUrl: item.avatarUrl
            )
            cell.cellDelegate = self
            cell.setMask()
            cell.selectionStyle = .none
            
            return cell
        } else if item.isInvite {
            
            guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupInviteCell.cellName,
                                                           for: indexPath) as? GroupInviteCell else {
                fatalError()
            }
            
            cell.configure(
                primary: item.primary,
                title: item.title,
                invitedBy: item.value,
                subtitle: item.subtitle,
                descr: item.descr,
                jid: item.jid,
                owner: item.owner,
                showAvatar: true,
                avatarUrl: item.avatarUrl,
                members: item.members,
                bottomLine: item.bottomLine ?? ""
            )
            cell.cellDelegate = self
            cell.setMask()
            cell.selectionStyle = .none
            
            return cell
        } else if item.isButton {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableCell.cellName,
                                                           for: indexPath) as? ButtonTableCell else {
                fatalError()
            }
            cell.configure(title: item.title, subtitle: item.subtitle)
            cell.selectionStyle = .none
            
            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactCell.cellName,
                                                           for: indexPath) as? ContactCell else {
                fatalError()
            }
            
            cell.configure(
                title: item.title,
                subtitle: item.subtitle,
                bottomLine: item.bottomLine,
                groups: item.groups,
                jid: item.jid,
                owner: item.owner,
                showAvatar: true,
                avatarUrl: item.avatarUrl,
                entity: item.entity,
                status: item.status
            )
            cell.setMask()
            cell.selectionStyle = .none
            
            return cell
        }
        
    }
}

extension ContactsViewController: GroupListActionsCellDelegate {
    
    func onAcceptCallback(error: String?, primary: String) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
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
                    
                }
            }
        } else {
            do {
                let realm = try WRealm.safe()
                guard let invite = realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary) else {
                    return
                }
                let owner = invite.owner
                let jid = invite.groupchat
                try realm.write {
                    invite.isProcessed = true
                    invite.isRead = true
                }
                DispatchQueue.main.async {
//                    self.runDatasetUpdateTask()
                    self.leftMenuDelegate?.openChatlistWithChat(owner: owner, jid: jid, conversationType: .group, configure: nil)
                }
            } catch {
                DDLogDebug("ContacsViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    func acceptInvite(invitePrimary primary: String) {
        do {
            DispatchQueue.main.async {
                self.view.makeToastActivity(.center)
            }
            let realm = try WRealm.safe()
            guard let invite = realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary) else {
                return
            }
            let groupchat = invite.groupchat
            let owner = invite.owner
            XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
                if stream.isAuthenticated {
                    session.groupchat?.join(stream, uiConnection: true, groupchat: groupchat) { error in
                        self.onAcceptCallback(error: error, primary: primary)
                    }
                }
            } fail: {
                AccountManager.shared.find(for: invite.owner)?.action({ user, stream in
                    if stream.isAuthenticated {
                        user.groupchats.join(stream, uiConnection: true, groupchat: groupchat) { error in
                            self.onAcceptCallback(error: error, primary: primary)
                        }
                    }
                })
            }

            
        } catch {
            DDLogDebug("ContacsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func onCancelInvite(error: String?, primary: String, value: String) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
        }
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
                    
                }
            }
        } else {
            do {
                let realm = try WRealm.safe()
                guard let invite = realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary) else {
                    return
                }
                if value == "block" {
                    let invitedBy = invite.jid
                    AccountManager.shared.find(for: invite.owner)?.action({ user, stream in
                        user.blocked.blockContact(stream, jid: invitedBy)
                    })
                }
                try realm.write {
                    invite.isProcessed = true
                    invite.isRead = true
                }
                DispatchQueue.main.async {
                    self.runDatasetUpdateTask()
                }
            } catch {
                DDLogDebug("ContacsViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    func cancelInvite(invitePrimary primary: String) {
        ActionSheetPresenter().present(
            in: self,
            title: "Decline invite",
            message: nil,
            cancel: "Cancel",
            values: [
                ActionSheetPresenter.Item(destructive: false, title: "Decline invite", value: "decline"),
                ActionSheetPresenter.Item(destructive: true, title: "Decline and block", value: "block")
            ],
            animated: true) {
                
            } completion: { value in
                if value.isNotEmpty {
                    do {
                        DispatchQueue.main.async {
                            self.view.makeToastActivity(.center)
                        }
                        let realm = try WRealm.safe()
                        guard let invite = realm.object(ofType: GroupchatInvitesStorageItem.self, forPrimaryKey: primary) else {
                            return
                        }
                        let groupchat = invite.groupchat
                        let owner = invite.owner
                        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
                            if stream.isAuthenticated {
                                session.groupchat?.decline(stream, groupchat: groupchat) { error in
                                    self.onCancelInvite(error: error, primary: primary, value: value)
                                }
                            }
                        } fail: {
                            AccountManager.shared.find(for: invite.owner)?.action({ user, stream in
                                if stream.isAuthenticated {
                                    user.groupchats.decline(stream, groupchat: groupchat) { error in
                                        self.onCancelInvite(error: error, primary: primary, value: value)
                                    }
                                }
                            })
                        }
                    } catch {
                        DDLogDebug("ContacsViewController: \(#function). \(error.localizedDescription)")
                    }
                }
            }

    }
    
    
}

extension ContactsViewController: ContactCellSubscribtionActionsDelegate {
    func acceptSubscribtionRequest(jid: String, owner: String) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.subscribed(stream, jid: jid, storePreaproved: true)
            user.presences.subscribe(stream, jid: jid)
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: UINotificationStorageItem.self, forPrimaryKey: UINotificationStorageItem.genPrimary(owner: owner, jid: jid)) {
                    try realm.write {
                        realm.delete(instance)
                    }
                }
            } catch {
                DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
            }
        })
        DispatchQueue.main.async {
            self.leftMenuDelegate?.openChatlistWithChat(owner: owner, jid: jid, conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular, configure: nil)
        }
    }
    
    func cancelSubscribtionRequest(jid: String, owner: String) {
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: "Decline contact request",
            cancel: "Cancel",
            values: [
                ActionSheetPresenter.Item(destructive: false, title: "Decline", value: "decline"),
                ActionSheetPresenter.Item(destructive: true, title: "Decline and block", value: "block")
            ],
            animated: true) {
                
            } completion: { value in
                if value.isNotEmpty {
                    AccountManager.shared.find(for: owner)?.action({ user, stream in
                        user.presences.subscribed(stream, jid: jid, storePreaproved: true)
                        user.presences.subscribe(stream, jid: jid)
                        if value == "block" {
                            user.blocked.blockContact(stream, jid: jid)
                        }
                        do {
                            let realm = try WRealm.safe()
                            if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner)) {
                                try realm.write {
                                    instance.ask = .none
                                    instance.subscribtion = .none
                                    instance.removed = true
                                }
                            }
                        } catch {
                            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                        }
                    })
                }
            }

    }
}
