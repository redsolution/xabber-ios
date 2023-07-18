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

extension ContactsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .contact: return 64
        case .group: return 44
        case .collapsed: return 3
        case .collapsedLast: return 6
        case .noContact: return 0
        }
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if enabledAccounts.value.count < 2 {
            return 0
        }
        return 44
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 1
    }
    
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if self.isCellTapped {
            return
        }
        self.isCellTapped = true
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .group:
            if let group = item.groupPrimary {
                collapseGroup(group, value: !(item.collapsed ?? true))
            }
            tableView.deselectRow(at: indexPath, animated: true)
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
        case .contact:
            tableView.deselectRow(at: indexPath, animated: true)
            guard let jid = item.jid else { return }
            var groupchatDescr: String = ""
            var conversationType: ClientSynchronizationManager.ConversationType = .regular
            do {
                let realm = try WRealm.safe()
                if let instance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: [jid, item.owner].prp()) {
                    conversationType = .group
                    groupchatDescr = instance.descr
                }
            } catch {
                DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
            }
            let vc = ChatViewController()
            self.hidesBottomBarWhenPushed = false
            vc.hidesBottomBarWhenPushed = true
            vc.owner = item.owner
            vc.jid = jid
            vc.conversationType = conversationType
            vc.entity = item.entity ?? .contact
            vc.groupchatDescr = groupchatDescr
            self.navigationController?.pushViewController(vc, animated: true)
        default: break
        }
        do {
            self.isCellTapped = false
        }
    }
}
