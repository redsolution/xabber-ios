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

extension LastChatsViewController {
    internal var isShowingSearchResults: Bool {
        BottomInPlaceSearchHostHelper.shouldShowResults(
            searchView: bottomSearchHostView,
            updater: chatSearchResultsController
        )
    }

    internal func configureSearchBar() {
        navigationItem.searchController = nil
        installBottomSearchHostIfNeeded()
        BottomInPlaceSearchHostHelper.configure(
            searchView: bottomSearchHostView,
            updater: chatSearchResultsController,
            reload: { [weak self] in
                self?.reloadInPlaceSearchResultsIfNeeded()
            },
            activeChanged: { [weak self] _ in
                self?.bottomSearchPresentationStateDidChange()
            }
        )
        searchController.searchResultsUpdater = chatSearchResultsController
    }

    internal func dismissBottomSearchForRoute() {
        BottomInPlaceSearchHostHelper.dismiss(
            searchView: bottomSearchHostView,
            updater: chatSearchResultsController,
            reload: { [weak self] in
                self?.reloadInPlaceSearchResultsIfNeeded()
            },
            activeChanged: { [weak self] _ in
                self?.bottomSearchPresentationStateDidChange()
            }
        )
    }

    internal func bottomSearchPresentationStateDidChange() {
        refreshEmptyStateVisibility(isSearchActive: bottomSearchHostView.isExpanded)
        updateFloatingToolbarFilterButtonState()
        updateTableInsetsForFloatingToolbar()
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

extension LastChatsViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        
    }
}

extension LastChatsViewController: UISearchControllerDelegate {
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
