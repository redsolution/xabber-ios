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

extension GroupchatContactInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard datasource.indices.contains(section) else { return 0 }
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].childs.indices.contains(indexPath.row) else {
            preconditionFailure("Invalid canonical group member section")
        }
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .status:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName,
                                                           for: indexPath) as? StatusInfoCell else {
                fatalError()
            }
            if isBlocked {
                cell.configure(title: "Blocked".localizeString(id: "groupchat_blocked", arguments: []), status: .online, entity: .contact, isTemporary: false)
            } else {
                if self.userOnline {
                    cell.configure(title: "Online".localizeString(id: "account_state_connected", arguments: []), status: .online, entity: .contact, isTemporary: false)
                } else {
                    cell.configure(title: "Offline".localizeString(id: "unavailable", arguments: []), status: .offline, entity: .contact, isTemporary: false)
                }
            }
            
            cell.accessoryType = .none
            return cell
        case .text:
            var cell = tableView.dequeueReusableCell(withIdentifier: "TextCell")
            if cell == nil {
                cell = UITableViewCell(style: .value1, reuseIdentifier: "TextCell")
            }
            cell?.textLabel?.text = item.title
            cell?.detailTextLabel?.text = item.subtitle
            if item.key == "gcc_role" {
                if isBlocked {
                    cell?.detailTextLabel?.text = "Not a member".localizeString(id: "settings_group_member__placeholder_not_a_member", arguments: [])
                } else if isKicked {
                    cell?.detailTextLabel?.text = "Not a member".localizeString(id: "settings_group_member__placeholder_not_a_member", arguments: [])
                } else {
                    cell?.detailTextLabel?.text = self.userRole.localized
                }
            }
            cell?.selectionStyle = .none
            return cell!
        case .button:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.subtitle
            if item.key == "delete_chat_button" {
                cell.textLabel?.textColor = .systemRed
            } else {
                cell.textLabel?.textColor = .systemBlue
            }
            cell.selectionStyle = .none
            return cell
        case .selection:
            fatalError()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard datasource.indices.contains(section) else { return nil }
        return datasource[section].title
    }
}
