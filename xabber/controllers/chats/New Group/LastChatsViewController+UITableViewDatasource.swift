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
//            cell.animate()
            
            return cell
        }
        if showArchivedSection.value && indexPath.row == 0 {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ArchivedCell.cellName, for: indexPath) as? ArchivedCell else {
                fatalError()
            }
            
            cell.configure(title: "Archived chats".localizeString(id: "archived_chats_title", arguments: []),
                           text: self.archivedSectionSubtitleText,
                           count: self.unreadArchivedChatsCount)
            
            return cell
        } else {
            let index = showArchivedSection.value ? indexPath.row - 1 : indexPath.row
            let item = datasource[index]
            if item.verificationState != nil {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
                    fatalError()
                }
                
                let label: String
                let message: String
                
                if item.verificationState == VerificationSessionStorageItem.VerififcationState.receivedRequest || item.verificationState == VerificationSessionStorageItem.VerififcationState.acceptedRequest {
                    label = "Incoming verification request"
                    if item.verificationState == VerificationSessionStorageItem.VerififcationState.receivedRequest {
                        message = "User \(item.jid) want to establish a trusted connection with you"
                    } else {
                        message = "Tell \(item.jid) the code to continue verification"
                    }
                } else if item.verificationState == VerificationSessionStorageItem.VerififcationState.failed {
                    label = "Verification failed"
                    message = "Verification session with \(item.jid)"
                } else if item.verificationState == VerificationSessionStorageItem.VerififcationState.rejected {
                    label = "Verification rejected"
                    message = "Verification session with \(item.jid)"
                } else if item.verificationState == VerificationSessionStorageItem.VerififcationState.trusted {
                    label = "Verification successful"
                    message = "Verification session with \(item.jid)"
                } else {
                    label = "Outcoming verification request"
                    if item.verificationState == VerificationSessionStorageItem.VerififcationState.sentRequest {
                        message = "Verification request has been sent to the user \(item.jid)"
                    } else {
                        message = "Enter the code from user \(item.jid)"
                    }
                }
                
                cell.configure(
                    label,
                    owner: item.owner,
                    username: label,
                    message: "",
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
                    hasErrorInChat: item.hasErrorInChat
                )
                cell.setMask()
                cell.avatarView.image = UIImage(systemName: "person.badge.shield.checkmark")
                cell.avatarView.backgroundColor = .clear
                cell.statusIndicator.isHidden = true
                cell.messageLabel.text = message
                
                return cell
            }
            guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName,
                                                           for: indexPath) as? ChatListTableViewCell else {
                fatalError()
            }
            
            cell.configure(
                item.jid,
                owner: item.owner,
                username: item.username,
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
                hasErrorInChat: item.hasErrorInChat
            )
            cell.setMask()
            
            return cell
        }
        
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let count = datasource.count
        return showArchivedSection.value ? count + 1 : count
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if showArchivedSection.value && !(tableView.indexPathsForVisibleRows?.contains(IndexPath(row: 0, section: 0)) ?? false) {
            showArchivedSection.accept(false)
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset.y < -132 && scrollView.contentOffset.y > -232 {
            if archivedChats?.isEmpty ?? true { return }
            if filter.value != .chats { return }
            let alpha = (abs(scrollView.contentOffset.y) - 132.0) / 100
            if showArchivedSection.value {
                if self.pullDownTableHeaderView.alpha > alpha {
                    UIView.performWithoutAnimation {
                        self.pullDownTableHeaderView.alpha = alpha
                    }
                }
            } else {
                UIView.performWithoutAnimation {
                    self.pullDownTableHeaderView.alpha = alpha
                }
            }
            
        }
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if self.showSkeleton.value {
            (cell as? SkeletonCell)?.animate()
        }
    }
    
}
