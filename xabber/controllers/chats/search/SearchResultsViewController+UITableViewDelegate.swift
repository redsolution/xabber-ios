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

extension SearchResultsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch sections[indexPath.section].kind {
        case .contacts: return 64
        case .messages: return 72
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let section = isContactsHidden ? indexPath.section + 1 : indexPath.section
        switch sections[section].kind {
        case .contacts:
            guard let item = filteredContacts?[indexPath.row] else { return }
            delegate?.openChat(owner: item.owner, jid: item.jid, conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular)
        case .messages:
            guard let item = filteredMessages?[indexPath.row] else { return }
            delegate?.openChat(owner: item.owner, jid: item.opponent, conversationType: item.conversationType)
        }
    }
}
