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

extension GroupchatInviteListViewController {
    
    internal func onRevoke() {
        inSaveMode.accept(true)
        conflictJids.removeAll()
        revokedJids = selectedJids.value
        selectedJids.value.forEach {
            [unowned self] contact in
            AccountManager.shared.find(for: owner)?.action({ (user, stream) in
                user.groupchats.revokeInvite(stream, groupchat: self.jid, jid: contact, callback: self.willRevokeCallback)
            })
        }
    }

    internal func willRevokeCallback(_ contact: String, error: String?) {
        DispatchQueue.main.async {
            if error != nil {
                switch error {
                case "conflict":
                    self.revokeErrorMessage = "Some members already in groupchat"
                        .localizeString(id: "groupchats_members_in_groupchat_message", arguments: [])
                    self.conflictJids.insert(contact)
                case "not-allowed":
                    self.revokeErrorMessage = "You have no permission to invite members"
                        .localizeString(id: "groupchats_no_permission_to_invite", arguments: [])
                case "fail":
                    self.revokeErrorMessage = "Connection failed"
                        .localizeString(id: "grouchats_connection_failed", arguments: [])
                default:
                    self.revokeErrorMessage = "Internal server error"
                        .localizeString(id: "error_internal_server", arguments: [])
                }
            }
            self.revokedJids.remove(contact)
            if self.revokedJids.isEmpty {
                self.finishRevoking()
            }
        }

    }

    internal func finishRevoking() {
        inSaveMode.accept(false)
        selectedJids.accept([])
        if let error = revokeErrorMessage {
            ErrorMessagePresenter()
                .present(in: self,
                         message: error,
                         animated: true,
                         completion: nil)
        }
        revokeErrorMessage = nil
        self.tableView.reloadData()
        
//        if conflictJids.isEmpty {
//            self.navigationController?.dismiss(animated: true, completion: nil)
//        } else {
//            self.tableView.reloadData()
//        }
    }
    
}
