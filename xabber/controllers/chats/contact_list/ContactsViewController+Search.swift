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

extension ContactsViewController {
    internal var isShowingSearchResults: Bool {
        chatSearchResultsController.shouldShowResults(for: searchController)
    }
    
    @discardableResult
    internal func configureSearchBar(forceRebind: Bool = false) -> Bool {
        InPlaceSearchHostHelper.attach(
            searchController: searchController,
            to: self,
            updater: chatSearchResultsController,
            searchControllerDelegate: self,
            searchBarDelegate: self,
            forceRebind: forceRebind
        ) { [weak self] in
            self?.reloadInPlaceSearchResultsIfNeeded()
        }
    }

    internal func reloadInPlaceSearchResultsIfNeeded() {
        guard isViewLoaded else { return }
        UIView.performWithoutAnimation {
            tableView.reloadData()
        }
    }

    internal func clearInPlaceSearchResultsForDismissal() {
        chatSearchResultsController.reset()
        guard isViewLoaded else { return }
        UIView.performWithoutAnimation {
            tableView.reloadData()
        }
    }
}

extension ContactsViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        
    }
}

extension ContactsViewController: UISearchControllerDelegate {
    func presentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willPresentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
        refreshEmptyStateVisibility(isSearchActive: true)
    }
    
    func didPresentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
        refreshEmptyStateVisibility(isSearchActive: true)
    }
    
    func willDismissSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
        clearInPlaceSearchResultsForDismissal()
        refreshEmptyStateVisibility(isSearchActive: false)
    }
    
    func didDismissSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
        refreshEmptyStateVisibility(isSearchActive: false)
    }
}

extension ContactsViewController: SearchResultsDelegateProtocol {
    func openChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        let vc = ChatViewController()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
        showStacked(vc, in: self)
    }

    internal func openSearchResult(_ item: SearchResultsViewController.Datasource) {
        InPlaceSearchResultRouteHelper.open(
            item,
            searchController: searchController,
            updater: chatSearchResultsController,
            reload: { [weak self] in
                self?.reloadInPlaceSearchResultsIfNeeded()
            },
            openNewChat: { [weak self] item, completion in
                guard let self else {
                    completion(nil)
                    return
                }
                let vc = ChatViewController()
                vc.owner = item.owner
                vc.jid = item.jid
                vc.conversationType = item.conversationType
                showStacked(vc, in: self)
                completion(vc)
            }
        )
    }
}
