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

extension EditContactViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let target = textField.restorationIdentifier,
            target == "contact_new_group",
            let groupName = textField.text,
            groupName.isNotEmpty else {
            return true
        }
        textField.text = nil
        textField.resignFirstResponder()
        if selectedGroups.value.contains(groupName) {
            self.view.makeToast("Circle \"\(groupName)\" already exitsts".localizeString(id: "account_circle_already_exists", arguments: []))
        } else {
            let datasourceItem = Datasource(kind: .select, key: "circle", title: groupName, bool: true)
            let groupsCount = self.datasource[groupsSectionIndex].count
            let insertedIndexPath = IndexPath(row: groupsCount - 1, section: groupsSectionIndex)
            self.datasource[groupsSectionIndex].insert(datasourceItem, at: insertedIndexPath.row)
            if #available(iOS 11.0, *) {
                self.tableView.performBatchUpdates({
                    self.tableView.insertRows(at: [insertedIndexPath], with: .automatic)
                }) { (result) in
                    if result {
                        self.tableView.selectRow(at: insertedIndexPath, animated: true, scrollPosition: .none)
                    }
                }
            } else {
                self.tableView.beginUpdates()
                self.tableView.insertRows(at: [insertedIndexPath], with: .automatic)
                self.tableView.endUpdates()
                self.tableView.selectRow(at: insertedIndexPath, animated: true, scrollPosition: .none)
            }
            var selected = selectedGroups.value
            selected.insert(groupName)
            selectedGroups.accept(selected)
        }
        return true
    }
}
