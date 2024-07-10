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
        return self.sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section].kind {
            case .contacts:
                let item = self.contactsDatasource[indexPath.row]
                guard let cell = tableView
                    .dequeueReusableCell(withIdentifier: ContactsViewController.ContactCell.cellName,
                                         for: indexPath) as? ContactsViewController.ContactCell
                else {
                    fatalError()
                }
                cell.configure(
                    title: item.title ?? "",
                    subtitle: item.subtitle ?? "",
                    status: item.status ?? .offline,
                    entity: item.entity ?? .contact,
                    jid: item.jid,
                    owner: item.owner,
                    showAvatar: true,
                    avatarUrl: item.avatarUrl
                )
                cell.setMask()

                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
                cell.selectedBackgroundView = view

                return cell
            case .messages:
                let item = self.chatsDatasource[indexPath.row]
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
                    fatalError()
                }

                cell.configure(
                    item.jid,
                    owner: item.owner,
                    username: item.username,
                    attributedUsername: item.attributedUsername,
                    message: item.message,
                    date: item.date,
                    deliveryState: item.state,
                    isMute: item.isMute,
                    isSynced: item.isSynced,
                    isGroupchat: [.groupchat, .incognitoChat].contains(item.entity),
                    status: item.status,
                    entity: item.entity,
                    conversationType: item.conversationType,
                    unread: item.unread,
                    unreadString: item.unreadString,
                    indicator: item.color,
                    isDraft: item.isDraft,
                    isAttachment: item.hasAttachment,
                    groupchatNickname: item.userNickname,
                    isSystem: item.isSystemMessage,
                    isPinned: item.isPinned,
                    subRequest: item.subRequest,
                    avatarUrl: item.avatarUrl,
                    hasErrorInChat: item.hasErrorInChat,
                    verAction: false
                )
                cell.setMask()

                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
                cell.selectedBackgroundView = view

                return cell
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section].kind {
        case .contacts:
            return contactsDatasource.count
        case .messages:
            return chatsDatasource.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].header
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footer
    }
}
