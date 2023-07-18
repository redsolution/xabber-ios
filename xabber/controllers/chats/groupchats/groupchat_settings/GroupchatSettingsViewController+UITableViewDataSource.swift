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

extension GroupchatSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let item = datasource[section]
        switch item.kind {
        case .textSingle, .delete, .textMulti:
            return 1
        case .listSingle:
            return item.options.count
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section]
        switch item.kind {
        case .textSingle:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: TextItemCell.cellName,
                                     for: indexPath) as? TextItemCell else {
                fatalError()
            }
            
            cell.configure(item.itemId, placeholder: item.placeholder, value: item.value, enabled: !inSaveMode.value)
            cell.delegate = self
            
            return cell
            
        case .textMulti:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: LargeTextItemCell.cellName,
                                     for: indexPath) as? LargeTextItemCell else {
                fatalError()
            }
            
            cell.delegate = self
            cell.configure(item.itemId, placeholder: item.placeholder, value: item.value, enabled: !inSaveMode.value)
            
            return cell
            
        case .listSingle:
            let value = item.options[indexPath.row]
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: InfoCell.cellName,
                                     for: indexPath) as? InfoCell else {
                fatalError()
            }
            
            cell.configure(.info, title: (value["label"]) ?? "" , value: "", checked: item.value == ((value["value"]) ?? ""))
            if isStatus {
                cell.configureForStatus(value: value["show_status"], entity: self.entity)
            }
            return cell
            
        case .delete:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: InfoCell.cellName,
                                     for: indexPath) as? InfoCell else {
                fatalError()
            }
            
            cell.configure(.danger, title: item.value, value: "", checked: false)
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].header
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return datasource[section].footer
    }
    
}
