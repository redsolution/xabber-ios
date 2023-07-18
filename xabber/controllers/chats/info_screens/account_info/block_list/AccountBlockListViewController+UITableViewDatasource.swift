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

extension AccountBlockListViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let item = datasource?[indexPath.row],
            let cell = tableView.dequeueReusableCell(withIdentifier: ItemCell.cellName,
                                                     for: indexPath) as? ItemCell
            else {
                return UITableViewCell(frame: .zero)
        }
        cell.configure(item.jid, owner: self.owner, enabled: false)
        cell.setMask()
        return cell
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if datasource?.isEmpty ?? true {
            emptyStateLabel.isHidden = false
            return 0
        } else {
            if !emptyStateLabel.isHidden {
                emptyStateLabel.isHidden = true
            }
        }
        return datasource?.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if datasource?.isEmpty ?? true {
            return nil
        }
        return "Swipe left to unblock".localizeString(id: "account_settings_swipe_left_to_unblock", arguments: [])
    }
}
