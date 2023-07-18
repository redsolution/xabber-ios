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

extension AddContactViewController: UITextFieldDelegate {
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.restorationIdentifier == "new_group_field" {
            guard let newGroup = textField.text else { return false }
            if let childs = datasource.first(where: { $0.kind == .group })?.childs {
                let position = (childs.endIndex - 1) >= 0 ? childs.endIndex - 1 : 0
                datasource.first(where: { $0.kind == .group })?.childs.insert(Datasource(.group, title: newGroup), at: position)
                groupsChecked.insert(newGroup)
                textField.resignFirstResponder()
                if let index = datasource.firstIndex(where: { $0.kind == .group }) {
                    let insertedIndexPath = IndexPath(row: position, section: index)
                    if #available(iOS 11.0, *) {
                        self.tableView.performBatchUpdates({
                            tableView.insertRows(at: [insertedIndexPath], with: .automatic)
                        }) { (result) in
                            if result {
                                self.tableView.selectRow(at: insertedIndexPath, animated: true, scrollPosition: .none)
                            }
                        }
                    } else {
                        tableView.beginUpdates()
                        tableView.insertRows(at: [insertedIndexPath], with: .automatic)
                        tableView.endUpdates()
                        self.tableView.selectRow(at: insertedIndexPath, animated: true, scrollPosition: .none)
                    }
                }
                textField.text = nil
            }
        } else {
            textField.resignFirstResponder()
        }
        return true
    }
    
}
