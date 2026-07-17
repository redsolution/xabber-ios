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
        false
    }
    
    internal func configureSearchBar() {
        navigationItem.searchController = nil
        installBottomSearchHostIfNeeded()
        bottomSearchHostView.searchTextField.placeholder = contactsSearchPlaceholderText
        searchController.searchBar.placeholder = contactsSearchPlaceholderText
        bottomSearchHostView.onTransitionPhaseChanged = { [weak self] _ in
            self?.bottomSearchPresentationStateDidChange()
        }
        bottomSearchHostView.onBegin = { [weak self] in
            guard let self else { return }
            self.contactsSearchQuery = self.bottomSearchHostView.query
            self.runDatasetUpdateTask(force: true)
        }
        bottomSearchHostView.onQueryChanged = { [weak self] query in
            guard let self else { return }
            self.contactsSearchQuery = query
            self.runDatasetUpdateTask(force: true)
        }
        bottomSearchHostView.onCancel = { [weak self] in
            guard let self else { return }
            self.contactsSearchQuery = nil
            self.runDatasetUpdateTask(force: true)
        }
    }

    internal func dismissBottomSearchForRoute() {
        UIView.performWithoutAnimation {
            bottomSearchHostView.setQuery(nil, notify: false)
            bottomSearchHostView.setExpanded(false, animated: false)
            contactsSearchQuery = nil
            runDatasetUpdateTask(force: true)
            bottomSearchPresentationStateDidChange()
        }
    }

    internal func bottomSearchPresentationStateDidChange() {
        refreshEmptyStateVisibility(isSearchActive: bottomSearchHostView.isExpanded)
        updateContactsCompactBottomBarState()
        if isViewLoaded {
            view.bringSubviewToFront(bottomSearchHostView)
        }
    }

    internal func installBottomSearchHostIfNeeded() {
        guard isViewLoaded else { return }
        BottomInPlaceSearchHostHelper.install(
            searchView: bottomSearchHostView,
            in: view
        )
        updateTableInsetsForBottomSearch()
    }

    internal func updateTableInsetsForBottomSearch() {
        bottomOverlayInsetCoordinator.apply(
            to: tableView,
            in: view,
            overlays: [contactsCompactBottomBarView, bottomSearchHostView]
        )
    }

    internal func reloadInPlaceSearchResultsIfNeeded() {
        guard isViewLoaded else { return }
        UIView.performWithoutAnimation {
            tableView.reloadData()
        }
    }

    internal func clearInPlaceSearchResultsForDismissal() {
        contactsSearchQuery = nil
        guard isViewLoaded else { return }
        runDatasetUpdateTask(force: true)
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
