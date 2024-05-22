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

extension ContactsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .contact:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactCell.cellName,
                                                           for: indexPath) as? ContactCell else {
                fatalError()
            }
            cell.configure(
                title: item.title ?? "",
                subtitle: item.subtitle ?? "",
                status: item.status ?? .offline,
                entity: item.entity ?? .contact,
                jid: item.jid ?? item.owner,
                owner: item.owner,
                showAvatar: self.showAvatars,
                avatarUrl: item.avatarUrl
            )
            cell.setMask()
                
            let view = UIView()
            view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
            cell.selectedBackgroundView = view
            
            return cell
        case .group:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: GroupCell.cellName,
                                                           for: indexPath) as? GroupCell else {
                fatalError()
            }
            cell.configure(title: item.group ?? "", subtitle: item.subtitle, collapsed: item.collapsed ?? false)
            return cell
//
//        case .collapsed:
//            let cell = tableView.dequeueReusableCell(withIdentifier: CollapsedCell.cellName, for: indexPath)
//            if (self.datasource[indexPath.section].count - 1) == indexPath.row {
//                cell.separatorInset = UIEdgeInsets(top: 0, bottom: 0, left: self.view.frame.width, right: 0)
//            }
//            return cell
        case .collapsed, .collapsedLast:
            return tableView.dequeueReusableCell(withIdentifier: NewCollapsedCell.cellName, for: indexPath)
        case .noContact:
            return tableView.dequeueReusableCell(withIdentifier: "NoContactCell", for: indexPath)
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let account = enabledAccounts.value[section]
        let header = SectionHeader()
        header.setup()
        header.configure(
            collapsed: account.isCollapsed,
            title: AccountManager.shared.find(for: account.jid)?.username ?? account.jid,
            jid: account.jid,
            subtitle: "\(account.contactsCount)",
            color: AccountColorManager.shared.palette(for: account.jid).tint700
        )
        if #available(iOS 13.0, *) {
            header.backgroundColor = .systemBackground
        } else {
            header.backgroundColor = .white
        }
        header.collapseCallback = self.onAccountCollapse
        header.menuCallback = self.onManageAccount
        if enabledAccounts.value.count > 1 {
            if section > 0 && section != enabledAccounts.value.count {
                let topBorder = UIView(frame: CGRect(
                                            x: 0,
                                            y: 0,
                                            width: self.view.frame.width,
                                            height: 0.33))
                topBorder.backgroundColor = UIColor.black.withAlphaComponent(0.27)
                header.addSubview(topBorder)
            }
            let bottomBorder = UIView(frame: CGRect(
                                        x: 0,
                                        y: 43.66,
                                        width: self.view.frame.width,
                                        height: 0.33))
            bottomBorder.backgroundColor = UIColor.black.withAlphaComponent(0.27)
            header.addSubview(bottomBorder)
            
        }
        return header
    }
    
//    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
//        return UIView()
//    }
}
