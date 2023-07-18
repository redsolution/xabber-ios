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

extension GroupchatEditContactViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].rows.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].rows[indexPath.row]
        switch item.kind {
        case .textItem:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: TextEditCell.cellName,
                                     for: indexPath) as? TextEditCell else {
                fatalError()
            }
            cell.delegate = self
            cell.configure(item.itemId, placeholder: item.title, value: item.value)
            
            return cell
        case .listItem:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ListItemEditCell.cellName,
                                     for: indexPath) as? ListItemEditCell else {
                fatalError()
            }
            cell.delegate = self
            cell.configure(itemId: item.itemId, title: item.title, value: item.value)
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return datasource[section].footer
    }
}
