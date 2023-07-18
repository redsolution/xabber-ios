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

extension LastChatsViewController: XabberTabBarDelegate {
    func onSelect(_ tabBar: XabberTabBar, item: UITabBarItem, myTag: Int, tag: Int) {
        NotifyManager.shared.clearAllNotifications()
        filter.accept(.chats)
        item.image = #imageLiteral(resourceName: "chat-outline")
        item.selectedImage = #imageLiteral(resourceName: "chat-outline")
        item.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
        return
    }
    
    func onSelectCurrent(_ tabBar: XabberTabBar, item: UITabBarItem) {
        if datasource.isEmpty { return }
        if !isAppeared {
            return
        }
        switch filter.value {
        case .chats:
            if NotifyManager.shared.unreadMessagesCount > 0 {
                filter.accept(.unread)
                item.image = #imageLiteral(resourceName: "chat-alert-outline")
                item.selectedImage = #imageLiteral(resourceName: "chat-alert-outline")
                item.title = "Unread".localizeString(id: "unread_chats", arguments: [])
            } else {
                self.tableView.scrollToRow(at: IndexPath(item: 0, section: 0), at: .top, animated: true)
            }
        case .unread:
            filter.accept(.chats)
            item.image = #imageLiteral(resourceName: "chat-outline")
            item.selectedImage = #imageLiteral(resourceName: "chat-outline")
            item.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
        case .archived:
            break
        }
    }
}
