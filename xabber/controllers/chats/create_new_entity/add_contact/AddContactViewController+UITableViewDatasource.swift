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

extension AddContactViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .account:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: AccountCell.cellName, for: indexPath) as? AccountCell else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(for: item.title, decriptionText: item.value, editable: true)
            return cell
        case .field:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: EditCell.cellName, for: indexPath) as? EditCell else {
                return UITableViewCell(frame: .zero)
            }
            if item.key == "nickname_field" {
                cell.configure(item.key, for: self.contactNicknamePlaceholder ?? (contactJid.isNotEmpty ? contactJid : item.title), value: contactNickname)
            } else if item.key == "xmpp_id_field" {
                cell.configure(item.key, for: item.title, value: contactJid)
            } else {
                cell.configure(item.key, for: item.title, value: item.value)
            }
            cell.callback = onTextFieldDidChange
            cell.field.delegate = self
            return cell
        case .group:
//            guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupsCell.cellName, for: indexPath) as? GroupsCell else {
//                return UITableViewCell(frame: .zero)
//            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "GroupsCell", for: indexPath)
//            cell.configure(for: item.title, checked: groupsChecked.contains(item.title))
            cell.textLabel?.text = item.title
            return cell
        }
        
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].childs.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return datasource[section].value
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let item = datasource[indexPath.section].childs[indexPath.row]
        return item.kind == .group
    }
}
