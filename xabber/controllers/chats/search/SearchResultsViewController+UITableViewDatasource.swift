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

extension SearchResultsViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        if isMessagesHidden || isContactsHidden {
            return sections.count - 1
        }
        if isMessagesHidden && isContactsHidden {
            return 0
        }
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = isContactsHidden ? indexPath.section + 1 : indexPath.section
        switch sections[section].kind {
        case .contacts:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: ContactCell.cellName,
                                     for: indexPath) as? ContactCell,
                let item = filteredContacts?[indexPath.row]
                else {
                fatalError("cant dequeue reusable cell for identifier \(ContactCell.cellName)")
            }
            cell.configure(
                jid: item.jid,
                owner: item.owner,
                username: item.displayName,
                isGroupchat: false,
                status: item.getPrimaryResource()?.status ?? .offline,
                indicator: AccountManager.shared.activeUsers.value.count > 1 ? AccountColorManager.shared.primaryColor(for: item.owner) : .clear
            )
            cell.setMask()
            return cell
        case .messages:
            guard let cell = tableView
                .dequeueReusableCell(withIdentifier: MessageCell.cellName,
                                     for: indexPath) as? MessageCell,
                let item = filteredMessages?[indexPath.row]
                else {
                    fatalError("cant dequeue reusable cell for identifier \(MessageCell.cellName)")
            }
            let body = item.outgoing ? item.body : ["You:".localizeString(id: "you", arguments: []),item.body].joined(separator: "\n")
            cell.configure(
                jid: item.opponent,
                owner: item.owner,
                username: messagesMetadata[[item.opponent, item.owner, "username"].prp()] as? String ?? "None",
                message: body,
                status: .offline,
                isGroupchat: messagesMetadata[[item.opponent, item.owner, "groupchat"].prp()] as? Bool ?? false,
                isIncome: item.outgoing,
                date: item.date,
                accountColor: AccountManager.shared.activeUsers.value.count > 1 ? AccountColorManager.shared.primaryColor(for: item.owner) : .clear
            )
            cell.setMask()
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let sectionMod = isContactsHidden ? section + 1 : section
        switch sections[sectionMod].kind {
        case .contacts:
            return filteredContacts?.count ?? 0
        case .messages:
            return filteredMessages?.count ?? 0
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let sectionMod = isContactsHidden ? section + 1 : section
        return sections[sectionMod].header
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let sectionMod = isContactsHidden ? section + 1 : section
        return sections[sectionMod].footer
    }
        
}
