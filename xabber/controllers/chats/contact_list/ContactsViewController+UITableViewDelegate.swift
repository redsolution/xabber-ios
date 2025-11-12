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
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.//
//
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

extension ContactsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            return tableView.estimatedRowHeight
        }
        if item.isButton {
            return 40
        }
        if item.isInvite {
            return tableView.estimatedRowHeight
//            return 92
        }
        if isGroup {
            return 92
        }
        return 86
    }
    
//    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
//        return 1
//    }
    
    public func didSelectSpecialCategory(_ category: String) {
        switch category {
            case "show_all_contacts":
                self.category = "subscribtions"
                self.categoryDelegate?.filterDidSelect(category: "subscribtions")
            case "show_all_invites":
                self.category = "invitations"
                self.categoryDelegate?.filterDidSelect(category: "invitations")
            case "contacts":
                self.category = "all"
                self.categoryDelegate?.filterDidSelect(category: "all")
            case "public":
                self.category = "public"
                self.categoryDelegate?.filterDidSelect(category: "public")
            default:
                break
        }
    }
    
    public func selectSpecialCategory(_ category: String) {
        switch category {
            case "show_all_contacts":
                self.shouldFilterBy(category: "subscribtions")
                self.categoryDelegate?.filterDidSelect(category: "subscribtions")
            case "show_all_invites":
                self.shouldFilterBy(category: "invitations")
                self.categoryDelegate?.filterDidSelect(category: "invitations")
            case "contacts":
                self.shouldFilterBy(category: "all")
                self.categoryDelegate?.filterDidSelect(category: "all")
            case "public":
                self.shouldFilterBy(category: "public")
                self.categoryDelegate?.filterDidSelect(category: "public")
            default:
                break
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        if item.value.isNotEmpty {
            self.selectSpecialCategory(item.value)
        } else {
            if isGroup {
                let vc = GroupchatInfoViewController()
                vc.owner = item.owner
                vc.jid = item.jid
                vc.leftMenuDelegate = self.leftMenuDelegate
    //            vc.conversationType = item.conversationType
                showModal(vc)
            } else {
                let vc = ContactInfoViewController()
                vc.owner = item.owner
                vc.jid = item.jid
                vc.conversationType = item.conversationType
                vc.leftMenuDelegate = self.leftMenuDelegate
                showModal(vc)
            }
        }
    }
}

