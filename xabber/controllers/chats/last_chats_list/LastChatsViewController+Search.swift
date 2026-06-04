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

enum LastChatsSearchChromePolicy {
    static func apply(
        to searchBar: UISearchBar,
        isContinuousSplitBackgroundActive: Bool
    ) {
        guard isContinuousSplitBackgroundActive else { return }

        searchBar.searchBarStyle = .default
        searchBar.backgroundColor = nil
        searchBar.isTranslucent = true
        searchBar.setBackgroundImage(nil, for: .any, barMetrics: .default)

        let textField = searchBar.searchTextField
        textField.backgroundColor = nil
        textField.layer.backgroundColor = nil
        textField.layer.masksToBounds = false
        textField.setNeedsLayout()
        textField.layoutIfNeeded()
    }
}

extension LastChatsViewController {

    internal func applySearchChromeForCurrentPresentation() {
        LastChatsSearchChromePolicy.apply(
            to: searchController.searchBar,
            isContinuousSplitBackgroundActive: ContinuousSplitBackgroundExperiment.isActive
        )
    }

    internal func prepareSearchChromeForNavigationTransitionFirstFrame() {
        applySearchChromeForCurrentPresentation()
        UIView.performWithoutAnimation {
            searchController.searchBar.setNeedsLayout()
            searchController.searchBar.layoutIfNeeded()
            navigationController?.navigationBar.setNeedsLayout()
            navigationController?.navigationBar.layoutIfNeeded()
        }
    }
    
    internal func configureSearchBar() {
        if isFirstLayoutSearchController {
            return
        }
        isFirstLayoutSearchController = false
//        searchController.searchBar.backgroundColor = .white
//        searchController.searchBar.barTintColor = .gray
//        searchController.searchBar.tintColor = .blue
//        searchController.searchBar.barStyle = .default
        applySearchChromeForCurrentPresentation()
        if #available(iOS 16.0, *) {
            navigationItem.preferredSearchBarPlacement = .stacked
        }
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.searchController = searchController
//        searchController.searchBar.sizeToFit()
        (searchController.searchResultsUpdater as? SearchResultsViewController)?.presenter = self
        searchController.automaticallyShowsSearchResultsController = true
        
        searchController.delegate = self
        searchController.searchBar.delegate = self
        definesPresentationContext = true
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
        refreshEmptyStateVisibility(isSearchActive: false)
    }
    
    func didDismissSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
        refreshEmptyStateVisibility(isSearchActive: false)
    }
}
