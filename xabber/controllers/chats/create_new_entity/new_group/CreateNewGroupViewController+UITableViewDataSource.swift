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

extension CreateNewGroupViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch datasource[indexPath.section][indexPath.row] {
        case .common:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: GroupInfoCell.cellName,
                                     for: indexPath) as? GroupInfoCell else {
                fatalError()
            }
            
            cell.delegate = self
            cell.configure("name", placeholder: "Group name".localizeString(id: "groupchat_name", arguments: []),
                           value: name.value)
                        
            return cell
        case .server:
            
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: JidSelectCell.cellName,
                                     for: indexPath) as? JidSelectCell else {
                fatalError()
            }
            
//            cell.configure(nil, for: "", localpart: "")
            cell.delegate = self
            cell.configure("localpart",
                           localpart: localpart,
                           placeholder: "XMPP ID",
                           server: ["@", server["value"]!].joined())
            
            return cell
            
        case .privacy, .membership, .index, .account:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ItemCell.cellName,
                                     for: indexPath) as? ItemCell else {
                fatalError()
            }
            
            switch datasource[indexPath.section][indexPath.row] {
            case .account:
                cell.configure(account["label"] ?? "", value: "")
            case .privacy:
                cell.configure("Privacy".localizeString(id: "privacy", arguments: []),
                               value: privacy["label"] ?? "")
            case .membership:
                cell.configure("Membership".localizeString(id: "groupchat_membership", arguments: []),
                               value: membership["label"] ?? "")
            case .index:
                cell.configure("Index".localizeString(id: "groupchat_index", arguments: []),
                               value: index["label"] ?? "")
            default: break
            }
            
            return cell
        case .description:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: DescriptionCell.cellName,
                                     for: indexPath) as? DescriptionCell else {
                fatalError()
            }
            
            cell.configure(for: descr)
            cell.delegate = self
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sectionHeaders[section]
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sectionFooter[section]
    }
    
}
