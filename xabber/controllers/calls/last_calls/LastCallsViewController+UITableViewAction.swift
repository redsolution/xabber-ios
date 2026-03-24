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
    
    internal func showContactInfo(for item: Datasource) {
        let vc = ContactInfoViewController()
        vc.owner = item.owner
        vc.jid = item.jid
        self.navigationItem.title = " "
        self.title = " "
        navigationController?.pushViewController(vc, animated: true)
    }
    
    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let item = self.datasource[indexPath.row]
        let infoAction = UITableViewRowAction(style: .normal,
                                              title: "Info".localizeString(id: "info", arguments: [])) {
            (action, indexPath) in
            self.showContactInfo(for: item)
        }
        
        let deleteAction = UITableViewRowAction(style: .destructive,
                                                title: "Delete".localizeString(id: "contact_delete", arguments: [])) {
            (action, indexPath) in
            self.onDelete(item)
        }
        
        infoAction.backgroundColor = MDCPalette.blue.tint500
        deleteAction.backgroundColor = MDCPalette.red.tint500
        
        return [deleteAction, infoAction]
    }
    
}

@available(iOS 11.0, *)
extension LastCallsViewController {
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.datasource[indexPath.row]
        let infoAction = UIContextualAction(style: .normal,
                                            title: "Info".localizeString(id: "info", arguments: [])) {
            (action, view, callback) in
            self.showContactInfo(for: item)
            callback(true)
        }
        let deleteAction = UIContextualAction(style: .destructive,
                                              title: "Delete".localizeString(id: "contact_delete", arguments: [])) {
            (action, view, callback) in
            self.onDelete(item)
            callback(true)
        }
        
        if let image = UIImage(systemName: "info.circle")?.withRenderingMode(.alwaysTemplate) {
            infoAction.image = image
        }
        if let image = imageLiteral( "trash")?.withRenderingMode(.alwaysTemplate) {
            deleteAction.image = image
        }
        infoAction.backgroundColor = MDCPalette.blue.tint500
        deleteAction.backgroundColor = MDCPalette.red.tint500
            
        return UISwipeActionsConfiguration(actions: [deleteAction, infoAction])
        
    }
}
