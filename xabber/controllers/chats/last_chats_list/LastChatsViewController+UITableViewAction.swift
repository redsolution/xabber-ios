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

extension LastChatsViewController {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        let isMuted = self.datasource[index].isMute
        let deleteAction = UIContextualAction(style: .destructive,
                                              title: "Delete".localizeString(id: "delete", arguments: [])) {
            (action, view, handler) in
            let item = self.datasource[index]
            let jid = item.jid
            let owner = item.owner
            let conversationType = item.conversationType
            self.onDelete(jid, owner: owner, conversationType: conversationType, displayName: item.username)
            handler(true)
        }
        
        deleteAction.image = imageLiteral( "trash")?.withRenderingMode(.alwaysTemplate)
        deleteAction.backgroundColor = .systemRed
        
        let archiveAction = UIContextualAction(style: .normal,
                                               title: "Archive".localizeString(id: "archive_chat", arguments: [])) {
            (action, view, handler) in
            let item = self.datasource[index]
            let jid = item.jid
            let owner = item.owner
            let conversationType = item.conversationType
            self.onArchive(jid, owner: owner, conversationType: conversationType, reverse: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if indexPath.row - 1 >= 0 && indexPath.row < self.datasource.count {
                    let topIndexPath = IndexPath(row: indexPath.row - 1, section: indexPath.section)
                    self.tableView.reloadRows(at: [topIndexPath], with: .none)
                }
                if indexPath.row < self.datasource.count {
                    self.tableView.reloadRows(at: [indexPath], with: .none)
                }
            }
            handler(true)
        }
        
        archiveAction.image = imageLiteral( "archive-put-filled")?.withRenderingMode(.alwaysTemplate)
        archiveAction.backgroundColor = .systemGreen
        
        let unarchiveAction = UIContextualAction(style: .normal,
                                                 title: "Unarchive".localizeString(id: "unarchive_chat", arguments: [])) {
            (action, view, handler) in
            let item = self.datasource[index]
            let jid = item.jid
            let owner = item.owner
            let conversationType = item.conversationType
            self.onArchive(jid, owner: owner, conversationType: conversationType, reverse: true)
            handler(true)
        }
        
        unarchiveAction.image = imageLiteral( "archive-remove-filled")?.withRenderingMode(.alwaysTemplate)
        unarchiveAction.backgroundColor = .systemGray3
        
        let muteAction = UIContextualAction(style: .normal, title: isMuted ?
                                            "Unmute".localizeString(id: "unmute_chat", arguments: []) :
                                            "Mute".localizeString(id: "mute_chat", arguments: [])) {
            action, view, handler in
            let item = self.datasource[index]
            let jid = item.jid
            let owner = item.owner
            let conversationType = item.conversationType
            self.onChangeNotifications(jid: jid, owner: owner, isMuted: isMuted, conversationType: conversationType)
            handler(true)
        }
        
        muteAction.backgroundColor = .systemBlue
        if isMuted {
            muteAction.image = imageLiteral( "bell")?.withRenderingMode(.alwaysTemplate)
        } else {
            muteAction.image = imageLiteral( "bell-off")?.withRenderingMode(.alwaysTemplate)
        }

        var actions: [UIContextualAction] = []
        let item = self.datasource[index]
        switch item.specialMessageKind {
            case .none:
                if filter.value == .archived {
                    actions = [unarchiveAction, deleteAction, muteAction]
                } else {
                    actions = [archiveAction, deleteAction, muteAction]
                }
                if AccountManager.shared.connectingUsers.value.isEmpty {
                    let configuration = UISwipeActionsConfiguration(actions: actions)
                    return configuration
                } else {
                    return nil
                }
            default:
                break
        }
        return nil
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        if AccountManager.shared.connectingUsers.value.isEmpty {
            let pinAction = UIContextualAction(style: .normal,
                                               title: "Pin".localizeString(id: "message_pin", arguments: [])) {
                action, view, handler in
                let item = self.datasource[index]
                let jid = item.jid
                let owner = item.owner
                let conversationType = item.conversationType
                self.pinChat(jid: jid, owner: owner, conversationType: conversationType)
                handler(true)
            }
            pinAction.image = imageLiteral( "pin")?.withRenderingMode(.alwaysTemplate)
            pinAction.backgroundColor = .systemGreen
            return UISwipeActionsConfiguration(actions: [pinAction])
        } else {
            return nil
        }
    }
}
