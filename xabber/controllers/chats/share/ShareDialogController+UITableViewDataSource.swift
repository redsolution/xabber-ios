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

extension ShareDialogController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
            fatalError()
        }
        let item = datasource[indexPath.row]
        cell.configure(
            item.jid,
            owner: item.owner,
            username: item.username,
            attributedUsername: nil,
            message: item.message,
            date: item.date,
            deliveryState: item.deliveryState,
            isMute: item.isMute,
            isSynced: item.isSynced,
            isGroupchat: item.isGroupchat,
            status: item.status,
            entity: item.entity,
            conversationType: item.conversationType,
            unread: item.unread,
            unreadString: item.unreadString,
            indicator: item.indicator,
            isDraft: item.isDraft,
            isAttachment: item.isAttachment,
            groupchatNickname: item.groupchatNickname,
            isSystem: item.isSystem,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )
        cell.setMask()
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    
}
