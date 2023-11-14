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

extension CloudStorageViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].children.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].children[indexPath.row]
        
        switch item.key {
        case "quota_info":
            let cell = tableView.dequeueReusableCell(withIdentifier: QuotaInfoCell.cellName, for: indexPath) as? QuotaInfoCell
            cell?.selectionStyle = .none
            cell?.setup(title: item.title, owner: jid, quotaDelegate: self)
            return cell!
        case "delete_files":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
            var listContentConfiguration = cell.defaultContentConfiguration()
            listContentConfiguration.text = item.title
            listContentConfiguration.textProperties.color = .systemRed
            listContentConfiguration.textProperties.alignment = .center
            if imagesUsed == "0 KiB" && videosUsed == "0 KiB" && audioUsed == "0 KiB" && filesUsed == "0 KiB" {
                cell.selectionStyle = UITableViewCell.SelectionStyle.none
                listContentConfiguration.textProperties.color = .systemGray
            } else if (100 * usedQuota / quota) < 80 {
                listContentConfiguration.textProperties.color = .systemBlue
            } else {
                listContentConfiguration.textProperties.color = .systemRed
            }
            cell.contentConfiguration = listContentConfiguration
            return cell
        default:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "value1CellReuseID")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.subtitle
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
}
