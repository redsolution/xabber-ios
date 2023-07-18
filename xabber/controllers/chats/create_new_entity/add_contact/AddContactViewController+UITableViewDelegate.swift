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

extension AddContactViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .account:
            let vc = AccountSelectViewController()
            vc.configure(self, current: owner)
            navigationController?.pushViewController(vc, animated: true)
        case .field:
            break
        case .group:
//            if groupsChecked.contains(item.title) {
//                groupsChecked.remove(item.title)
//            } else {
            groupsChecked.insert(item.title)
//            }
//            tableView.reloadRows(at: [indexPath], with: .automatic)
        }
    }
    
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section].childs[indexPath.row]
        switch item.kind {
        case .account:
            let vc = AccountSelectViewController()
            vc.configure(self, current: owner)
            navigationController?.pushViewController(vc, animated: true)
        case .field:
            break
        case .group:
            groupsChecked.remove(item.title)
        }
    }
}
