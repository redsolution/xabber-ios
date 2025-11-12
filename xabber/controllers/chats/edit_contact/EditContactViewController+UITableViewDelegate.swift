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

extension EditContactViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
            case .field:
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
            case .select:
                return 42
            default:
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .field:
            break
        case .select:
            var selected = selectedGroups.value
            if selected.contains(item.title) {
                selected.remove(item.title)
            } else {
                selected.insert(item.title)
            }
            datasource[indexPath.section][indexPath.row].selectedValue = !(item.selectedValue ?? false)
            selectedGroups.accept(selected)
            self.tableView.reloadRows(at: [indexPath], with: .automatic)
        case .simple:
            switch item.key {
            case "presence_receive":
                self.onPresenceReceiveRowTap()
            case "presence_send":
                self.onPresenceSendRowTap()
            default:
                break
            }
        case .danger:
            switch item.key {
            case "delete":
                self.deleteContact()
            default:
                break
            }
        default:
            break
        }
    }
    
}
