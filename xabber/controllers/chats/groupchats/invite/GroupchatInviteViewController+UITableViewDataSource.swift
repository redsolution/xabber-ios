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

extension GroupchatInviteViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
//        return datasource[section].childs.count
        if collapsedGroups.value.contains(datasource[section].name) {
            return 0
        } else {
            return datasource[section].childs.count
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if collapsedGroups.value.contains(datasource[indexPath.section].name) {
            return tableView.dequeueReusableCell(withIdentifier: "UITableViewCell", for: indexPath)
        } else {
            let item = datasource[indexPath.section].childs[indexPath.row]
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ContactCell.cellName,
                                     for: indexPath) as? ContactCell else {
                fatalError()
            }
                
            cell.configure(item.jid,
                           owner: owner,
                           username: item.username,
                           status: item.status,
                           entity: .contact,
                           avatarKey: item.jid,
                           selected: selectedJids.value.contains(item.jid),
                           failed: conflictJids.contains(item.jid))
            cell.setMask()
            
            if selectedJids.value.contains(item.jid) {
                self.tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            } else {
                self.tableView.deselectRow(at: indexPath, animated: false)
            }
            return cell
        }
        
    }
    
//    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
//        return nil//datasource[section].name
//    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView
            .dequeueReusableHeaderFooterView(withIdentifier: HeaderView.headerView) as? HeaderView else {
            fatalError()
        }
        header.delegate = self
        header.configure(title: datasource[section].name,
                         collapsed: collapsedGroups.value.contains(datasource[section].name))
        
        return header
    }
    
}
