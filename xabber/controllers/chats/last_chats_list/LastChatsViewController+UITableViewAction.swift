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
    internal static let swipeActionIconNames = [
        "archivebox.fill",
        "archivebox",
        "bell",
        "bell.slash",
        "trash",
        "pin",
        "phone.fill",
        "hand.raised.fill"
    ]

    internal static func swipeActionDatasourceKey(for item: Datasource) -> String {
        [item.jid, item.owner, item.conversationType.rawValue].prp()
    }

    internal static func canShowCallAction(for item: Datasource) -> Bool {
        guard item.specialMessageKind == .none else { return false }
        return [.regular, .omemo, .omemo1, .axolotl].contains(item.conversationType)
    }

    internal static func canShowBlockAction(for item: Datasource) -> Bool {
        guard item.specialMessageKind == .none else { return false }
        return ![.saved, .notifications].contains(item.conversationType)
    }

    internal static func filterReloadIndexPaths(
        _ indexPaths: [IndexPath],
        datasource: [Datasource],
        activeSwipeActionDatasourceKey: String?
    ) -> [IndexPath] {
        guard let activeSwipeActionDatasourceKey else { return indexPaths }
        return indexPaths.filter { indexPath in
            guard indexPath.section == 0,
                  datasource.indices.contains(indexPath.row) else {
                return true
            }
            return swipeActionDatasourceKey(for: datasource[indexPath.row]) != activeSwipeActionDatasourceKey
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
        let item = self.datasource[index]
        let isMuted = item.isMute
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
            handler(true)
        }

        archiveAction.image = imageLiteral( "archivebox.fill")?.withRenderingMode(.alwaysTemplate)
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

        unarchiveAction.image = imageLiteral( "archivebox")?.withRenderingMode(.alwaysTemplate)
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
            muteAction.image = imageLiteral( "bell.slash")?.withRenderingMode(.alwaysTemplate)
        }

        let blockAction = UIContextualAction(style: .normal,
                                             title: "Block".localizeString(id: "contact_bar_block", arguments: [])) {
            action, view, handler in
            let item = self.datasource[index]
            self.onBlock(jid: item.jid, owner: item.owner, displayName: item.username)
            handler(true)
        }
        blockAction.image = imageLiteral("hand.raised.fill")?.withRenderingMode(.alwaysTemplate)
        blockAction.backgroundColor = .systemRed

        var actions: [UIContextualAction] = []
        switch item.specialMessageKind {
            case .none:
                if filter.value == .archived {
                    actions = [unarchiveAction, deleteAction, muteAction]
                } else {
                    actions = [archiveAction, deleteAction, muteAction]
                }
                if Self.canShowBlockAction(for: item) {
                    actions.append(blockAction)
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
        let item = self.datasource[index]
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

            let callAction = UIContextualAction(style: .normal,
                                               title: "Call".localizeString(id: "call", arguments: [])) {
                action, view, handler in
                let item = self.datasource[index]
                self.onCall(jid: item.jid, owner: item.owner)
                handler(true)
            }
            callAction.image = imageLiteral("phone.fill")?.withRenderingMode(.alwaysTemplate)
            callAction.backgroundColor = .systemBlue

            var actions = [pinAction]
            if Self.canShowCallAction(for: item) {
                actions.append(callAction)
            }
            return UISwipeActionsConfiguration(actions: actions)
        } else {
            return nil
        }
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        guard datasource.indices.contains(indexPath.row) else {
            activeSwipeActionDatasourceKey = nil
            return
        }
        activeSwipeActionDatasourceKey = Self.swipeActionDatasourceKey(for: datasource[indexPath.row])
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        finishActiveSwipeActionEditing()
    }
}
