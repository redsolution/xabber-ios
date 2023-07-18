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

protocol NewCallViewControllerDelegate {
    func startCall(owner: String, jid: String)
}

extension NewCallViewController: NewCallViewControllerDelegate {
    func startCall(owner: String, jid: String) {
        VoIPManager.shared.startCall(owner: owner, jid: jid)
//        self.dismiss(animated: true, completion: nil)
    }
}

extension NewCallViewController {
        
    internal func configureSearchBar() {
//        searchController.searchBar.backgroundColor = .white
//        searchController.searchBar.barTintColor = .gray
//        searchController.searchBar.tintColor = .blue
        searchController.searchBar.barStyle = .default
        navigationItem.searchController = searchController
        searchController.searchBar.sizeToFit()
        (searchController.searchResultsUpdater as? NewCallSearchViewController)?.delegate = self
        
//        searchController.dimsBackgroundDuringPresentation = false
        if #available(iOS 13.0, *) {
            searchController.automaticallyShowsSearchResultsController = true
        }
        searchController.delegate = self
        searchController.searchBar.delegate = self
        
        definesPresentationContext = true
    }
}

extension NewCallViewController: UISearchBarDelegate {
    
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
    
}

extension NewCallViewController: UISearchControllerDelegate {
    
    func presentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
    }
    
    func willPresentSearchController(_ searchController: UISearchController) {
        print("UISearchControllerDelegate invoked method: \(#function).")
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
