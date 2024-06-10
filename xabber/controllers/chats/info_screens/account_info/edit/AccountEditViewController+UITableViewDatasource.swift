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

extension AccountEditViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
            case .profile:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ProfileCell.cellName, for: indexPath) as? ProfileCell else {
                    fatalError()
                }
                cell.callback = onAvatarButtonDidPress
                cell.usernameCallback = onProfileChanged
                do {
                    
                } catch {
                    
                }
                cell.configure(avatarUrl: self.avatarUrl,
                               nickname: self.nickname,
                               jid: jid,
                               editable: false,
                               given: item.givenName,
                               middle: item.middleName,
                               family: item.family,
                               fullname: item.fullname)
                cell.givenNameField.delegate = self
                cell.familyNameField.delegate = self
                cell.setMask()
                return cell
            case .vcard:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: VcardEditedItem.cellName, for: indexPath) as? VcardEditedItem else {
                    fatalError()
                }
                if item.key == "ci_nickname" {
                    cell.configure(item.key, for: nickname.isNotEmpty ? nickname : item.title, value: item.value)
                } else {
                    cell.configure(item.key, for: item.title, value: item.value)
                }
                cell.field.delegate = self
                cell.callback = textWasEdited
                return cell
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "Your name and an optional profile picture".localizeString(id: "vcard_basic_info", arguments: [])
        }
        return ""
    }
    
}
