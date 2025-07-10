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

extension ChatViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        print("done")
        if self.showSkeletonObserver.value {
            return
        }
        guard let searchText = searchBar.text else {
            return
        }
        print(searchText)
        searchTextObserver.accept(searchText.isEmpty ? nil : searchText)
    }
    
    fileprivate func cancelSearch() {
        if self.showSkeletonObserver.value {
            return
        }
        self.currentSearchQueryId = nil
//        self.messagesCollectionView.reconfigureItems(at: self.messagesCollectionView.indexPathsForVisibleItems)
        searchBar.resignFirstResponder()
        searchBar.endEditing(true)
        self.inSearchMode.accept(false)
        self.becomeFirstResponder()
        self.searchTextObserver.accept(nil)
        self.configureNavbar()
        self.navigationItem.setLeftBarButton(self.navigationItem.backBarButtonItem, animated: true)
        self.navigationItem.setHidesBackButton(false, animated: true)
        self.messagesCollectionView.reloadDataAndKeepOffset()
    }
    
    @objc
    internal func pnCancelButtonTouchUp(_ sender: UIBarButtonItem) {
        self.cancelSearch()
    }
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        self.cancelSearch()
    }
    
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        
    }
}

