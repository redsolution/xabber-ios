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

extension LastChatsViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showSkeleton.value {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SkeletonCell.cellName, for: indexPath) as? SkeletonCell else {
                fatalError()
            }
            return cell
        }

        let index = indexPath.row
        let item = datasource[index]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName,
                                                       for: indexPath) as? ChatListTableViewCell else {
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
            verAction: item.isVerificationActionRequired
        )
        cell.setMask()
        
        let view = UIView()
        view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
        cell.selectedBackgroundView = view
    
        return cell
        
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
//        if showArchivedSection.value && !(tableView.indexPathsForVisibleRows?.contains(IndexPath(row: 0, section: 0)) ?? false) {
//            showArchivedSection.accept(false)
//        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
//        if scrollView.contentOffset.y < -132 && scrollView.contentOffset.y > -232 {
//            if archivedChats?.isEmpty ?? true { return }
//            if filter.value != .chats { return }
//            let alpha = (abs(scrollView.contentOffset.y) - 132.0) / 100
//            if showArchivedSection.value {
//                if self.pullDownTableHeaderView.alpha > alpha {
//                    UIView.performWithoutAnimation {
//                        self.pullDownTableHeaderView.alpha = alpha
//                    }
//                }
//            } else {
//                UIView.performWithoutAnimation {
//                    self.pullDownTableHeaderView.alpha = alpha
//                }
//            }
//            
//        }
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if self.showSkeleton.value {
            (cell as? SkeletonCell)?.animate()
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if AudioManager.shared.player == nil {
            return nil
        } else {
            return self.playerViewToolbar
        }
    }
    
}
