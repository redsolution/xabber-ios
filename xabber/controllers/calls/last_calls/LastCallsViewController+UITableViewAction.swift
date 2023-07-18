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


extension LastCallsViewController {
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        
        let deleteAction = UITableViewRowAction(style: .destructive,
                                                title: "Delete".localizeString(id: "contact_delete", arguments: [])) {
            (action, indexPath) in
//            guard let item = self.calls?[indexPath.row] else { return }
//            var sid = item.sid
//            self.onDelete(sid)
        }
        
        deleteAction.backgroundColor = MDCPalette.red.tint500
        
        return [deleteAction]
    }
    
}

@available(iOS 11.0, *)
extension LastCallsViewController {
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive,
                                              title: "Archive".localizeString(id: "archive_chat", arguments: [])) {
            (action, view, callback) in
//            guard let item = self.calls?[indexPath.row] else { return }
//            var sid = item.sid
//            self.onDelete(sid)
        }
        
        
        deleteAction.image = #imageLiteral(resourceName: "trash").withRenderingMode(.alwaysTemplate)
        deleteAction.backgroundColor = MDCPalette.red.tint500
            
        return UISwipeActionsConfiguration(actions: [deleteAction])
        
    }
}

