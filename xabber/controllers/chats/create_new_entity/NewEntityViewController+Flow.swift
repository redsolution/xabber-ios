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

protocol NewEntityViewControllerDelegate {
    func openChat(_ jid: String, owner: String)
}

extension NewEntityViewController {
    @objc
    internal func close() {
        self.dismiss(animated: true) {
            
        }
    }
    
    internal func addContact() {
        let vc = AddContactViewController()
        vc.delegate = self.addContactDelegate
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func addGroup() {
        let vc = CreateNewGroupViewController()
        vc.delegate = self.addContactDelegate
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func addIncognitoGroup() {
        let vc = CreateNewGroupViewController()
        vc.createIncognitoGroup = true
        vc.delegate = self.addContactDelegate
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    
    internal func openChat(at indexPath: IndexPath) {
        guard let item = contacts?[indexPath.row] else { return }
        let jid = item.jid
        let owner = item.owner
        self.dismiss(animated: false) {
            self.delegate?.openChat(jid, owner: owner)
        }
    }
    
    internal func startSecretChat() {
        let vc = NewSecretChatViewController()
        vc.delegate = self.addContactDelegate
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal func openQRCodeScanner() {
        let vc = QRCodeScannerViewController()
//        self.navigationController?.pushViewController(vc, animated: true)
//        let vc = QRCodeViewController()
//        vc.username = displayedName
//        vc.jid = self.jid
//        vc.stringValue = "xmpp:\(self.jid)"
        vc.delegate = self
        vc.modalTransitionStyle = .coverVertical
        vc.modalPresentationStyle = .overFullScreen
        present(vc, animated: true, completion: nil)
    }
}

extension NewEntityViewController: QRCodeScannerDelegate {
    func didReceive(jid: String, username: String?) {
        let vc = AddContactViewController()
        vc.delegate = self.addContactDelegate
        vc.contactJid = jid
        vc.contactNicknamePlaceholder = username
        vc.doneButtonActive.accept(true)
        self.title = " "
        self.navigationController?.title = " "
        self.navigationController?.pushViewController(vc, animated: true)
    }
}

extension NewEntityViewController {
    
    internal func configureSearchBar() {
        
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false

        } else {
            searchController.dimsBackgroundDuringPresentation = false
            searchController.searchBar.backgroundColor = .white
            searchController.searchBar.barTintColor = .gray
            searchController.searchBar.tintColor = .blue
            searchController.searchBar.barStyle = .default
            searchController.searchBar.sizeToFit()
            tableView.tableHeaderView = searchController.searchBar
        }
        (searchController.searchResultsUpdater as? NewEntitySearchViewController)?.callback = onSearchItemSelected
        
                
        searchController.delegate = self
        searchController.searchBar.delegate = self
        
        definesPresentationContext = true
    }
    
    func onSearchItemSelected(_ jid: String, owner: String) {
        self.dismiss(animated: false) {
            self.delegate?.openChat(jid, owner: owner)
        }
    }
}

extension NewEntityViewController: UISearchBarDelegate {
    
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
    
}

// MARK: - UISearchControllerDelegate

// Use these delegate functions for additional control over the search controller.

extension NewEntityViewController: UISearchControllerDelegate {
    
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
