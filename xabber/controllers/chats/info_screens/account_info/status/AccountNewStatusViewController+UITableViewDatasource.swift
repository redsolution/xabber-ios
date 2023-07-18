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

extension AccountNewStatusViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .custom:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: CustomStatus.cellName, for: indexPath) as? CustomStatus else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(for: item.title, value: item.value)
            cell.field.delegate = self
            cell.callback = updateCreditionals
            return cell
        case .basic:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: BaseStatus.cellName, for: indexPath) as? BaseStatus else {
                return UITableViewCell(frame: .zero)
            }
            cell.configure(status: item.status, current: item.current)
//            if item.status == datasource[indexPath.section].status {
//                cell.setSelected(true, animated: true)
//            }
            return cell
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return datasource[section].title
    }
}
