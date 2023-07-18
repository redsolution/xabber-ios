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

extension GroupchatInviteViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 38
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 64
    }
    
    
    internal func updateSelection(_ jid: String, current indexPath: IndexPath) {
        var indexPaths: [IndexPath] = []
        datasource.forEach {
            group in
            if let section = datasource.firstIndex(of: group) {
                if !collapsedGroups.value.contains(group.name) {
                    group.childs.filter { $0.jid == jid }.forEach {
                        item in
                        if let row = group.childs.firstIndex(of: item) {
                            let cellPath = IndexPath(row: row, section: section)
                            if cellPath != indexPath {
                                indexPaths.append(cellPath)
                            }
                        }
                    }
                }
            }
        }
        if #available(iOS 11.0, *) {
            self.tableView.performBatchUpdates({
                self.tableView.reloadRows(at: indexPaths, with: .automatic)
            }, completion: nil)
        } else {
            self.tableView.beginUpdates()
            self.tableView.reloadRows(at: indexPaths, with: .automatic)
            self.tableView.endUpdates()
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let jid = datasource[indexPath.section].childs[indexPath.row].jid
        var values = selectedJids.value
        values.insert(jid)
        selectedJids.accept(values)
        updateSelection(jid, current: indexPath)
    }
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        let jid = datasource[indexPath.section].childs[indexPath.row].jid
        var values = selectedJids.value
        values.remove(jid)
        selectedJids.accept(values)
        updateSelection(jid, current: indexPath)
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: true)
    }
}
