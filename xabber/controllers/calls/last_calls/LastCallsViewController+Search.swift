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

extension LastCallsViewController {
    internal var isShowingSearchResults: Bool {
        false
    }
    
    internal func configureSearchBar() {
        navigationItem.searchController = nil
        installBottomSearchHostIfNeeded()
        bottomSearchHostView.searchTextField.placeholder = callsSearchPlaceholderText
        searchController.searchBar.placeholder = callsSearchPlaceholderText
        bottomSearchHostView.onTransitionPhaseChanged = { [weak self] _ in
            self?.bottomSearchPresentationStateDidChange()
        }
        bottomSearchHostView.onBegin = { [weak self] in
            guard let self else { return }
            self.callsSearchQuery = self.bottomSearchHostView.query
            self.reloadCallDatasource()
        }
        bottomSearchHostView.onQueryChanged = { [weak self] query in
            guard let self else { return }
            self.callsSearchQuery = query
            self.reloadCallDatasource()
        }
        bottomSearchHostView.onCancel = { [weak self] in
            guard let self else { return }
            self.callsSearchQuery = nil
            self.reloadCallDatasource()
        }
    }

    internal func dismissBottomSearchForRoute() {
        UIView.performWithoutAnimation {
            bottomSearchHostView.setQuery(nil, notify: false)
            bottomSearchHostView.setExpanded(false, animated: false)
            callsSearchQuery = nil
            reloadCallDatasource()
            bottomSearchPresentationStateDidChange()
        }
    }

    internal func bottomSearchPresentationStateDidChange() {
        refreshEmptyStateVisibility(isSearchActive: bottomSearchHostView.isExpanded)
        updateCallsCompactBottomBarState()
        updateTableInsetsForBottomSearch()
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
        updateCallsCompactBottomBarState()
        updateTableInsetsForBottomSearch()
    }

    internal func updateTableInsetsForBottomSearch() {
        let isBottomSearchVisible = bottomSearchHostView.superview != nil && !bottomSearchHostView.isHidden
        let isCompactBarVisible = callsCompactBottomBarView.superview != nil && !isCallsCompactBottomBarHidden
        let bottomInset = isBottomSearchVisible || isCompactBarVisible
            ? max(BottomSearchHostView.Metrics.reservedBottomInset, FloatingBottomBarView.Metrics.reservedBottomInset)
            : 0

        if tableView.contentInset.bottom != bottomInset {
            tableView.contentInset.bottom = bottomInset
        }
        if tableView.verticalScrollIndicatorInsets.bottom != bottomInset {
            tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }

    internal func reloadInPlaceSearchResultsIfNeeded() {
        guard isViewLoaded else { return }
        UIView.performWithoutAnimation {
            tableView.reloadData()
        }
    }

    internal func clearInPlaceSearchResultsForDismissal() {
        callsSearchQuery = nil
        guard isViewLoaded else { return }
        reloadCallDatasource()
    }
}

extension LastCallsViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        
    }
}

extension LastCallsViewController: UISearchControllerDelegate {
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
