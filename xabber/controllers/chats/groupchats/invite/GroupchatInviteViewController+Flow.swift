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

enum CanonicalGroupInviteErrorPresentation {
    static func condition(for error: Error) -> String? {
        guard case let GroupchatServiceError.iq(stanzaError) = error else {
            return nil
        }
        return stanzaError.condition
    }
}

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
        guard let account = AccountManager.shared.find(for: owner) else {
            inviteErrorMessage = "Connection failed"
                .localizeString(id: "grouchats_connection_failed", arguments: [])
            finishInviting()
            return
        }
        inSaveMode.accept(true)
        conflictJids.removeAll()
        invitedJids = selectedJids.value
        invitedJidsCount = invitedJids.count
        errorJidsCount = 0
        let targets = selectedJids.value.sorted()
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            let repository: GroupRepository
            let privacy: GroupPrivacy
            do {
                repository = try GroupRepository(realm: WRealm.safe())
                // Missing legacy privacy fails closed into server-mediated
                // delivery so the inviter's real JID is never leaked.
                privacy = try repository.projection(
                    owner: self.owner,
                    groupJID: self.jid
                ).state.snapshot.privacy ?? .incognito
            } catch {
                self.inviteErrorMessage = "Internal server error"
                    .localizeString(id: "error_internal_server", arguments: [])
                self.finishInviting()
                return
            }
            for target in targets {
                do {
                    let authoritativeTargets = try await account.groupchatService.invite(
                        groupJID: self.jid,
                        targetJID: target,
                        privacy: privacy
                    )
                    _ = try repository.replaceOutgoingInvites(
                        owner: self.owner,
                        groupJID: self.jid,
                        targets: authoritativeTargets
                    )
                } catch {
                    self.errorJidsCount += 1
                    switch CanonicalGroupInviteErrorPresentation.condition(for: error) {
                    case "conflict":
                        self.conflictJids.insert(target)
                    case "not-allowed", "forbidden":
                        self.inviteErrorMessage = "You have no permission to invite members"
                            .localizeString(id: "groupchats_no_permission_to_invite", arguments: [])
                    default:
                        self.inviteErrorMessage = "Internal server error"
                            .localizeString(id: "error_internal_server", arguments: [])
                    }
                }
                self.invitedJids.remove(target)
            }
            self.finishInviting()
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
