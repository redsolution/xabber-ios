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

extension CreateNewGroupViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch datasource[indexPath.section][indexPath.row] {
            case .common:
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
            case .privacy, .index, .membership, .server, .account:
                if #available(iOS 26, *) {
                    return 52
                } else {
                    return 44
                }
            case .description:
                return 128
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch datasource[indexPath.section][indexPath.row] {
            case .account:
                let vc = CreateNewGroupEditViewController()
                vc.configure(AccountManager.shared.users.compactMap { return ["type": "default", "label": $0.jid, "value": $0.jid]},
                             title: "Select account".localizeString(id: "choose_account", arguments: []),
                             header: nil,
                             footer: "Selected account would be a groupchat owner".localizeString(id: "groupchats_new_groupchat_owner", arguments: []),
                             current: account) { (value) in
                    self.account = value
                    self.refreshGroupServiceSelection(reloadTable: false)
                    DispatchQueue.main.async {
                        var paths = [IndexPath(row: self.datasource[0].firstIndex(where: { $0 == .account })!, section: 0)]
                        if let servicePath = self.groupServiceIndexPath() {
                            paths.append(servicePath)
                        }
                        self.tableView.reloadRows(at: paths, with: .none)
                    }
                                
                    
                }
                navigationController?.pushViewController(vc, animated: true)
            case .server:
                guard let selectedServer = self.selectedServer else { return }
                let vc = CreateNewGroupSelectJIDViewController()
                vc.selectedLocalPart = self.localpart ?? ""
                vc.serviceJID = selectedServer
                vc.delegate = self
                navigationController?.pushViewController(vc, animated: true)
            case .privacy:
                let vc = CreateNewGroupEditViewController()
                vc.configure([["type": "default",
                               "label": "Public".localizeString(id: "groupchat_status_public", arguments: []),
                               "value": "public"],
                              ["type": "default",
                               "label": "Incognito".localizeString(id: "groupchat_privacy_type_incognito", arguments: []),
                               "value": "incognito"]],
                             title: "Privacy".localizeString(id: "privacy", arguments: []),
                             header: "",
                             footer: "In incognito groupchats nobody knows who is you and you don`t know this too"
                                .localizeString(id: "groupchats_incognito_hint", arguments: []),
                             current: privacy) { (value) in
                    self.privacy = value
                    
                    if AccountManager.shared.users.count > 1 {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[3].firstIndex(where: { $0 == .privacy })!, section: 3)], with: .none)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[2].firstIndex(where: { $0 == .privacy })!, section: 2)], with: .none)
                        }
                    }
                }
                navigationController?.pushViewController(vc, animated: true)
            case .membership:
                let vc = CreateNewGroupEditViewController()
                vc.configure([["type": "default",
                               "label": "Open".localizeString(id: "groupchat_membership_type_open", arguments: []),
                               "value": "open"],
                              ["type": "default",
                               "label": "Private".localizeString(
                                id: "groupchat_membership_type_private",
                                arguments: []
                               ),
                               "value": GroupMembership.privateGroup.rawValue]],
                             title: "Membership".localizeString(id: "groupchat_membership", arguments: []),
                             header: "",
                             footer: "Private groups can be joined only by invitation"
                                .localizeString(id: "groupchats_private_membership_hint", arguments: []),
                             current: membership) { (value) in
                    self.membership = value
                    if AccountManager.shared.users.count > 1 {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[3].firstIndex(where: { $0 == .membership })!, section: 3)], with: .none)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[2].firstIndex(where: { $0 == .membership })!, section: 2)], with: .none)
                        }
                    }
                }
                navigationController?.pushViewController(vc, animated: true)
            case .index:
                let vc = CreateNewGroupEditViewController()
                vc.configure([["type": "default",
                               "label": "None".localizeString(id: "groupchat_membership_type_none", arguments: []),
                               "value": "none"],
                              ["type": "default",
                               "label": "Local".localizeString(id: "groupchat_index_type_local", arguments: []),
                               "value": "local"],
                              ["type": "default",
                               "label": "Global".localizeString(id: "groupchat_status_global", arguments: []),
                               "value": "global"]],
                             title: "Index".localizeString(id: "groupchat_index", arguments: []),
                             header: "",
                             footer: "Choose a mechanism to index your groupchat"
                                .localizeString(id: "groupchats_choose_a_mechanism_to_index", arguments: []),
                             current: index) { (value) in
                    self.index = value
                    if AccountManager.shared.users.count > 1 {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[3].firstIndex(where: { $0 == .index })!, section: 3)], with: .none)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.datasource[2].firstIndex(where: { $0 == .index })!, section: 2)], with: .none)
                        }
                    }
                }
                navigationController?.pushViewController(vc, animated: true)
            default: break
        }
    }
}
extension CreateNewGroupViewController: CreateNewGroupSelectJIDViewControllerDelegate {
    func onUpdateLocalPart(_ localPart: String) {
        self.localpart = localPart
        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
    }
    
}
