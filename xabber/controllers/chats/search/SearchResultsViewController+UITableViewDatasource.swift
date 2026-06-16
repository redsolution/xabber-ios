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
//  with this program; if not, write to the Free Software Foujrtndation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit

extension SearchResultsViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
            fatalError()
        }
        
        guard let item = item(at: indexPath) else {
            fatalError()
        }
        
        configureSearchResultCell(cell, with: item)

        return cell
    }

    internal func item(at indexPath: IndexPath) -> Datasource? {
        guard sections.indices.contains(indexPath.section) else { return nil }

        switch sections[indexPath.section].kind {
        case .contacts:
            guard chatsDatasource.indices.contains(indexPath.row) else { return nil }
            return chatsDatasource[indexPath.row]
        case .messages:
            guard messagesDatasource.indices.contains(indexPath.row) else { return nil }
            return messagesDatasource[indexPath.row]
        }
    }

    internal func configureSearchResultCell(_ cell: ChatListTableViewCell, with item: Datasource) {
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

        let isSelected = isCurrentSearchResult(item)
        cell.applyPlainGroupedSystemBackground(
            selectedColor: isSelected
                ? AccountSelectionHighlightStyle.tint50(
                    owner: item.owner,
                    fallbackOwners: Set(enabledAccounts)
                )
                : nil,
            isSelected: isSelected,
            usesHighlightedStateForSelection: false,
            usesStateDrivenSelection: false
        )
    }

    internal func isCurrentSearchResult(_ item: Datasource) -> Bool {
        guard let currentVc else { return false }

        return currentVc.jid == item.jid
            && currentVc.owner == item.owner
            && currentVc.conversationType == item.conversationType
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }

        switch sections[section].kind {
        case .contacts:
            return chatsDatasource.count
        case .messages:
            return messagesDatasource.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections.indices.contains(section) else { return nil }
        return sections[section].header
    }
    
//    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
////        return sections[section].footer
//        return nil
//    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard sections.indices.contains(section),
              sections[section].kind == .messages else {
            return nil
        }
        if self.isLoadingDone {
            return nil
        }
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return indicator
    }
}
