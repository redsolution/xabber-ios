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

extension LastChatsViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if AudioManager.shared.player == nil {
            return 0
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if self.showSkeleton.value {
            return
        }
        let item = self.datasource[indexPath.row]
        if let oldVc = self.currentChatVC,
           oldVc.jid == item.jid, oldVc.owner == item.owner, oldVc.conversationType == item.conversationType {
            oldVc.scrollToLastOrUnreadItem()
            return
        }
        self.currentChatVC = nil
        let vc = ChatViewController()
        vc.owner = item.owner
        vc.jid = item.jid
        vc.conversationType = item.conversationType
        vc.sharedPlayerPaneldelegae = self
        vc.lastChatsDisplayDelegate = self
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "split" {
            self.currentChatVC = vc
            self.playerViewToolbar.delegate = vc
        }
        showStacked(vc, in: self)
    }
}

protocol LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType)
}

extension LastChatsViewController: LastChatsDisplayDelegate {
    func shouldMakeDialogSelected(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        if let index = self.datasource.firstIndex(where: {
            return $0.jid == jid && $0.owner == owner && $0.conversationType == conversationType
        }) {
            self.tableView
                .indexPathsForSelectedRows?
                .compactMap { $0 }
                .forEach { self.tableView.deselectRow(at: $0, animated: true) }
            self.tableView.selectRow(at: IndexPath(row: index, section: 0), animated: true, scrollPosition: .middle)
        }
    }
    
    
}
