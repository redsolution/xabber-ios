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
import MaterialComponents.MDCPalettes
import XMPPFramework

extension AddContactViewController {
    internal func onTextFieldDidChange(_ key: String, value: String?) {
        switch key {
        case "xmpp_id_field": contactJid = value ?? ""
        case "nickname_field": contactNickname = value ?? ""
        default: break
        }
        doneButtonActive.accept(validate())
        guard key == "xmpp_id_field",
            value != nil,
            let section = datasource.firstIndex(where: { $0.key == "nickname_field" }),
            let row = datasource[section].childs.firstIndex(where: { $0.key == "nickname_field" }) else {
                return
        }
        tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .none)
    
        
    }
    
    internal func validate() -> Bool {
        guard AccountManager.shared.find(for: owner)?.xmppStream.isAuthenticated == true,
            contactJid.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty == true,
            XMPPJID(string: contactJid) != nil else {
                return false
        }
        return true
    }
    
    internal func onAdd() {
        self.view.endEditing(true)
        guard validate() else {
            return
        }
        
        if contactJid.contains("@") {
            guard let formatJid = XMPPJID(string: contactJid),
                  let localpart = formatJid.user,
                  localpart.isNotEmpty else {
                return
            }
            contactJid = formatJid.bare
        } else {
            let host = CommonConfigManager.shared.get().locked_host
            guard let formatJid = XMPPJID(user: contactJid, domain: host, resource: nil),
                  let localpart = formatJid.user,
                  localpart.isNotEmpty else {
                return
            }
            contactJid = formatJid.bare
        }
        
        self.inSaveMode.accept(true)
        AccountManager.shared.find(for: owner)?.action({ (user, stream) in
            if !stream.isAuthenticated {
                DispatchQueue.main.async {
                    self.view.makeToast("Connection error: account offline".localizeString(id: "connection_error_account_offline", arguments: []))
                }
                return
            }
            user.presences.sendSubscribtionRequest(stream, jid: self.contactJid)
            user.roster.setContact(stream,
                                   jid: self.contactJid,
                                   nickname: self.contactNickname,
                                   groups: self.groupsChecked.sorted())
            { (jid, error, success) in
                DispatchQueue.main.async {
                    self.inSaveMode.accept(false)
                    if success {
                        self.navigationController?.dismiss(animated: false) {
                            self.delegate?.didAddContact(
                                owner: self.owner,
                                jid: self.contactJid,
                                entity: .contact,
                                conversationType: .omemo
                            )
                        }
                    } else {
                        var message: String = "Internal error".localizeString(id: "message_manager_error_internal", arguments: [])
                        if let error = error {
                            switch error {
                            case "item-not-found":
                                message = "JID \(self.contactJid) not found".localizeString(id: "contact_jid_not_found", arguments: ["\(self.contactJid)"])
                            case "forbidden":
                                message = "Can`t perform request".localizeString(id: "contact_cant_perform_request", arguments: [])
                            case "not-acceptable":
                                message = "Invalid circles list".localizeString(id: "invalid_circles_list", arguments: [])
                            case "remote-server-not-found":
                                message = "Remote server not found".localizeString(id: "error_server_not_found", arguments: [])
                            default: break
                            }
                        }
                        self.view.makeToast(message)
                    }
                }
            }
        })
    }
}

