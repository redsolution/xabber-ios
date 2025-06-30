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

extension ContactsViewController {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.datasource[indexPath.section][indexPath.row]
        if item.kind != .contact { return nil }
        let deleteAction = UIContextualAction(style: .normal,
                                           title: "Pin".localizeString(id: "message_pin", arguments: [])) {
            action, view, handler in
            
            DeleteContactPresenter(username: item.title ?? "", jid: item.jid!, owner: item.owner).present(in: self, animated: true) {
                
            }
            
            handler(true)
        }
        deleteAction.image = imageLiteral("trash-outline")?.withRenderingMode(.alwaysTemplate)
        deleteAction.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        
        let item = self.datasource[indexPath.section][indexPath.row]
        if item.kind != .contact { return nil }
        
        let infoAction = UIContextualAction(style: .normal,
                                           title: "Pin".localizeString(id: "message_pin", arguments: [])) {
            action, view, handler in
            

            let vc = ContactInfoViewController()
            vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
            
            vc.owner = item.owner
            vc.jid = item.jid!
            showModal(vc, parent: self)
            
            handler(true)
        }
        infoAction.image = imageLiteral("info.circle.fill")
        infoAction.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [infoAction])
    }
}
