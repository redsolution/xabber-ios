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
import RealmSwift
import CocoaLumberjack

class NewCallViewController: BaseViewController {
    
    struct Datasource {
        let owner: String
        let jid: String
        let username: String
    }
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        
        return view
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = NewCallSearchViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search contacts".localizeString(id: "contact_search_hint", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = true
        controller.definesPresentationContext = true

        return controller
    }()
    
    internal var datasource: [Datasource] = []
    
    internal var randTitle: String = RandomTitleManager.shared.title()
    
    private final func load() {
        do {
            let realm = try WRealm.safe()
            let enabledAccounts = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .compactMap { return $0.jid }
            let contacts = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND subscription_ == %@ AND jid != owner",
                        Array(enabledAccounts),
                        RosterStorageItem.Subsccribtion.both.rawValue)
                .sorted(by: [SortDescriptor(keyPath: "jid", ascending: true),
                             SortDescriptor(keyPath: "username", ascending: true),
                             SortDescriptor(keyPath: "customUsername", ascending: true)])
            self.datasource = contacts.compactMap({ (item) -> Datasource? in
                switch item.getPrimaryResource()?.entity ?? .contact {
                case .contact:
                    return Datasource(owner: item.owner, jid: item.jid, username: item.displayName)
                default:
                    return nil
                }
            })
        } catch {
            DDLogDebug("NewCallViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    internal func close(_ sender: UIBarButtonItem) {
        self.dismiss(animated: true, completion: nil)
    }
    
    internal func configureNavbar() {
        navigationItem.setLeftBarButton(UIBarButtonItem(title: "Cancel".localizeString(id: "cancel_action", arguments: []),
                                                        style: .plain,
                                                        target: self,
                                                        action: #selector(close)),
                                        animated: true)
    }
    
    private final func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        configureNavbar()
        configureSearchBar()
        title = randTitle
        load()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
}
