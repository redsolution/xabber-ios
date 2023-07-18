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

extension GroupchatBlockedViewController {
    
    internal func onUnblock() {
        inSaveMode.accept(true)
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.unblockUser(stream,
                                           groupchat: self.jid,
                                           ids: Array(self.selectedIds.value),
                                           callback: self.onUnblockCallback)
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.unblockUser(stream,
                                            groupchat: self.jid,
                                            ids: Array(self.selectedIds.value),
                                            callback: self.onUnblockCallback)
            })
        }
        
    }
    
    internal func onUnblockCallback(_ error: String?) {
        DispatchQueue.main.async {
            self.inSaveMode.accept(false)
            if let error = error {
                self.conflictIds.removeAll()
                self.selectedIds.value.forEach { self.conflictIds.insert($0) }
                var message: String = ""
                switch error {
                case "conflict":
                    message = "Some members already unblocked"
                        .localizeString(id: "groupchats_members_in_groupchat_message", arguments: [])
                case "not-allowed":
                    message = "You have no permission to invite members"
                        .localizeString(id: "groupchats_no_permission_to_invite", arguments: [])
                case "fail":
                    message = "Connection failed"
                        .localizeString(id: "grouchats_connection_failed", arguments: [])
                default:
                    message = "Internal server error"
                        .localizeString(id: "error_internal_server", arguments: [])
                    self.conflictIds.removeAll()
                }
                ErrorMessagePresenter().present(in: self,
                                                message: message,
                                                animated: true,
                                                completion: nil)
            } else {
                self.selectedIds.accept(Set<String>())
            }
            self.tableView.reloadData()
            self.tableView.reloadSections(IndexSet(arrayLiteral: 0), with: .none)
            self.tableView.reloadSectionIndexTitles()
        }
        
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            session.groupchat?.requestUsers(stream, groupchat: self.jid)
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                user.groupchats.requestUsers(stream, groupchat: self.jid)
            })
        }
        
        
    }
    
}
