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
import CocoaLumberjack

extension LastChatsViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let item = item(at: indexPath),
              let sectionKind = sectionKind(at: indexPath.section) else {
            fatalError()
        }

        if showSkeleton.value {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: SkeletonCell.cellName, for: indexPath) as? SkeletonCell else {
                fatalError()
            }
            cell.applyContinuousSplitGlassBackground()
            return cell
        }

        switch sectionKind {
            case .chats:
                guard item.specialMessageKind == .none else {
                    fatalError()
                }
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName,
                                                               for: indexPath) as? ChatListTableViewCell else {
                    fatalError()
                }
                configureChatCell(cell, with: item)
                return cell
            case .specialMessages:
                guard item.specialMessageKind != .none else {
                    fatalError()
                }
                guard let cell = tableView.dequeueReusableCell(withIdentifier: SpecialMessageTableViewCell.cellName, for: indexPath) as? SpecialMessageTableViewCell else {
                    fatalError()
                }
                configureSpecialMessageCell(cell, with: item)
                return cell
        }
    }

    internal func configureChatCell(_ cell: ChatListTableViewCell, with item: Datasource) {
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
            hasUnreadMention: item.hasUnreadMention,
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

        let selectionColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
        if ContinuousSplitBackgroundExperiment.isActive {
            cell.applyContinuousSplitGlassBackground(selectedColor: selectionColor)
        } else {
            let view = UIView()
            view.backgroundColor = selectionColor
            cell.selectedBackgroundView = view
        }
    }

    internal func configureSpecialMessageCell(_ cell: SpecialMessageTableViewCell, with item: Datasource) {
        switch item.specialMessageKind {
        case .contact:
            cell.configure(
                title: "New contact request",
                subtitle: item.unread > 1 ? "New contact requests from: \(item.username) and others" : "New contact request from \(item.username)",
                avatars: item.avatars,
                owner: item.owner,
                key: "contact"
            )
        case .invite:
            cell.configure(
                title: "New invitations",
                subtitle: item.unread > 1 ? "Join new groups: \(item.username) and more" : "Join \(item.username)",
                avatars: item.avatars,
                owner: item.owner,
                key: "invite"
            )
        case .none:
            return
        }
        cell.closeCallback = onCloseNotificationCallback
        cell.applyContinuousSplitGlassBackground()
    }
    
    public func onCloseNotificationCallback(_ key: String) {
        do {
            let realm = try WRealm.safe()
            let jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
            switch key {
                case "contact":
                    let requests = realm
                        .objects(UINotificationStorageItem.self)
                        .filter("owner IN %@ AND isRead == %@ AND kind_ == %@", jids, false, UINotificationStorageItem.Kind.contactRequest.rawValue)
                    try realm.write {
                        requests.forEach {
                            $0.isRead = true
                            $0.readAt = Date()
                        }
                    }
                case "invite":
                    let uiInvites = realm
                        .objects(UINotificationStorageItem.self)
                        .filter("owner IN %@ AND isRead == %@ AND kind_ == %@", jids, false, UINotificationStorageItem.Kind.invite.rawValue)
                    let groupInvites = realm
                        .objects(GroupchatInvitesStorageItem.self)
                        .filter("owner IN %@ AND isRead == %@", jids, false)
                    try realm.write {
                        uiInvites.forEach {
                            $0.isRead = true
                            $0.readAt = Date()
                        }
                        groupInvites.forEach {
                            $0.isRead = true
                        }
                    }
                default:
                    break
            }
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasourceSections.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard datasourceSections.indices.contains(section) else { return 0 }
        return datasourceSections[section].rows.count
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

}
