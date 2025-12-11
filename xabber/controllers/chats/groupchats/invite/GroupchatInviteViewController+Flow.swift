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

extension GroupchatInviteViewController {
    
    internal func onSelectCallback(_ item: String) {
        var values = selectedJids.value
        values.insert(item)
        selectedJids.accept(values)
    }
    
    internal func onDeselectCallback(_ item: String) {
        var values = selectedJids.value
        values.remove(item)
        selectedJids.accept(values)
    }
    
    internal func configureSearchBar() {
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false

        } else {
            searchController.searchBar.backgroundColor = .white
            searchController.searchBar.barTintColor = .gray
            searchController.searchBar.tintColor = .blue
            searchController.searchBar.barStyle = .default
            searchController.searchBar.sizeToFit()
            tableView.tableHeaderView = searchController.searchBar
        }
        
        (searchController.searchResultsUpdater as? InviteSearchViewController)?.onSelectCallback = self.onSelectCallback
        (searchController.searchResultsUpdater as? InviteSearchViewController)?.onDeselectCallback = self.onDeselectCallback
        
                
        searchController.delegate = self
        searchController.searchBar.delegate = self
        
        definesPresentationContext = true
    }
    
    internal func onCancel() {
        self.selectedJids.accept(Set<String>())
        self.tableView.indexPathsForSelectedRows?.forEach {
            selectedPath in
            self.tableView.deselectRow(at: selectedPath, animated: true)
        }
    }
    
    internal func onInvite() {
        self.inSaveMode.accept(true)
        conflictJids.removeAll()
        invitedJids = selectedJids.value
        self.invitedJidsCount = invitedJids.count
        self.errorJidsCount = 0
        let jids = selectedJids.value
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
            jids.forEach {
                contact in
                session.groupchat?.willInvite(stream,
                                              groupchat: self.jid,
                                              jid: contact,
                                              callback: self.willInviteCallback)
            }
            
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                jids.forEach {
                    contact in
                    user.groupchats.willInvite(stream,
                                               groupchat: self.jid,
                                               jid: contact,
                                               callback: self.willInviteCallback)
                }
            })
        }
//        selectedJids.value.forEach {
//            contact in
//            
//            
//        }
    }
    
    internal func willInviteCallback(_ contact: String, error: String?) {
        DispatchQueue.main.async {
            if error != nil {
                switch error {
                case "conflict":
                    self.conflictJids.insert(contact)
//                    if self.conflictJids.count > 1 {
//                        self.inviteErrorMessage = "Failed to send invitations".localizeString(id: "groupchat__toast_failed_to_sent_invitations[other]", arguments: [])
//                    } else {
//                        self.inviteErrorMessage = "Failed to send invitation".localizeString(id: "groupchat__toast_failed_to_sent_invitations[one]", arguments: [])
//                    }
                case "not-allowed":
                    self.inviteErrorMessage = "You have no permission to invite members"
                        .localizeString(id: "groupchats_no_permission_to_invite", arguments: [])
                case "fail":
                    self.inviteErrorMessage = "Connection failed"
                        .localizeString(id: "grouchats_connection_failed", arguments: [])
                default:
                    self.inviteErrorMessage = "Internal server error"
                        .localizeString(id: "error_internal_server", arguments: [])
                }
            } else {
                XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
                    session.groupchat?.didInvite(stream, groupchat: self.jid, jid: contact)
                }) {
                    AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                        user.groupchats.didInvite(stream, groupchat: self.jid, jid: contact)
                    })
                }
                
            }
            self.invitedJids.remove(contact)
            if self.invitedJids.isEmpty {
                self.finishInviting()
            }
        }
        
    }
    
    internal func finishInviting() {
        if let error = inviteErrorMessage {
            ErrorMessagePresenter()
                .present(in: self,
                         message: error,
                         animated: true,
                         completion: nil)
        } else {
            if self.invitedJidsCount > 1 {
                ErrorMessagePresenter()
                    .present(in: self,
                             message: "Invitations sent"
                                .localizeString(id: "groupchat__toast__invitations_sent[other]", arguments: []),
                             animated: true,
                             completion: nil)
            } else {
                ErrorMessagePresenter()
                    .present(in: self,
                             message: "Invitation sent"
                                .localizeString(id: "groupchat__toast__invitations_sent[one]", arguments: []),
                             animated: true,
                             completion: nil)
            }
            self.invitedJidsCount = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.inSaveMode.accept(false)
                self.selectedJids.accept([])
                self.dismiss(animated: true, completion: nil)
            }
        }
        inviteErrorMessage = nil
        if conflictJids.isEmpty {
            self.tableView
                .indexPathsForSelectedRows?
                .forEach { self.tableView
                    .deselectRow(at: $0, animated: true) }
//            self.navigationController?.dismiss(animated: true, completion: nil)
//            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { (stream, session) in
//                session.groupchat?.requestInvitedUsers(stream, groupchat: self.jid)
//            }) {
//                AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
//                    user.groupchats.requestInvitedUsers(stream, groupchat: self.jid)
//                })
//            }
        } else {
            self.tableView.reloadData()
        }
    }
}

extension GroupchatInviteViewController: UISearchBarDelegate {
    
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
    
}

// MARK: - UISearchControllerDelegate

// Use these delegate functions for additional control over the search controller.

extension GroupchatInviteViewController: UISearchControllerDelegate {
    
    func presentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willPresentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
//        navigationController.tool
    }
    
    func didPresentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willDismissSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func didDismissSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
}
