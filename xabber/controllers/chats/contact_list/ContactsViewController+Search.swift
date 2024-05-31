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
    
    internal func configureSearchBar() {
        searchController.searchBar.backgroundColor = .white
        searchController.searchBar.barTintColor = .gray
        searchController.searchBar.tintColor = .blue
        searchController.searchBar.barStyle = .default
        navigationItem.searchController = searchController
        searchController.searchBar.sizeToFit()
        (searchController.searchResultsUpdater as? SearchResultsViewController)?.delegate = self
        if #available(iOS 13.0, *) {
            searchController.automaticallyShowsSearchResultsController = true
        }
        searchController.delegate = self
        searchController.searchBar.delegate = self
        definesPresentationContext = true
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

extension ContactsViewController: SearchResultsDelegateProtocol {
    func openChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        let vc = ChatViewController()
        vc.owner = owner
        vc.jid = jid
        vc.conversationType = conversationType
        self.navigationController?.pushViewController(vc, animated: true)
    }
}
