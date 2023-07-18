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
import RxRealm
import RxSwift
import CocoaLumberjack
import TOInsetGroupedTableView

class NewEntityViewController: BaseViewController {
    
    struct Datasource {
        
        enum Kind {
            case addGroup
            case addIncognitoGroup
            case addContact
            case startSecretChat
        }
        
        let kind: Kind
        let icon: UIImage
        let title: String
    }
     
    open var delegate: NewEntityViewControllerDelegate? = nil
    open var addContactDelegate: AddContactDelegate? = nil
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.separatorStyle = .none
                
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
        
        return view
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = NewEntitySearchViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults// as? UISearchResultsUpdating
//        controller.searchBar.searchBarStyle = .
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search contacts".localizeString(id: "contact_search_hint", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.obscuresBackgroundDuringPresentation = true
//        controller.dimsBackgroundDuringPresentation = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = false
        controller.searchBar.searchFieldBackgroundPositionAdjustment = UIOffset(horizontal: 0, vertical: 4)
        
        return controller
    }()
    
    internal func activateConstraints() {
        
    }
    
    internal var datasource: [Datasource] = []
    
    internal var contacts: Results<RosterStorageItem>? = nil
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var randTitle: String = RandomTitleManager.shared.title()
    
    internal func configureDatasource() {
        
        if CommonConfigManager.shared.config.locked_conversation_type == "none" {
            datasource = [
                Datasource(kind: .addContact, icon: #imageLiteral(resourceName: "contact-add"), title: "Add Contact".localizeString(id: "application_action_no_contacts", arguments: [])),
                Datasource(kind: .addGroup, icon: #imageLiteral(resourceName: "group-public-add"), title: "Create Group"),
                Datasource(kind: .addIncognitoGroup, icon: #imageLiteral(resourceName: "group-incognito-add"), title: "Create Incognito Group"),
                Datasource(kind: .startSecretChat, icon: #imageLiteral(resourceName: "security"), title: "Start secret chat")
            ]
        } else {
            datasource = [
                Datasource(kind: .addContact, icon: #imageLiteral(resourceName: "contact-add"), title: "Add Contact".localizeString(id: "application_action_no_contacts", arguments: []))
            ]
        }
        
    }
    
    internal func configureNavbar() {
//        navigationItem.setLeftBarButton(UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
//                                                        style: .plain,
//                                                        target: self,
//                                                        action: #selector(close)),
//                                        animated: true)
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            contacts = realm
                .objects(RosterStorageItem.self)
                .filter("isHidden == %@ AND removed == %@", false, false)
                .sorted(byKeyPath: "jid", ascending: true)
        } catch {
            DDLogDebug("NewEntityViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        configureDatasource()
        configureNavbar()
//        configureSearchBar()
        activateConstraints()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
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
        self.title = CommonConfigManager.shared.config.motivating ? self.randTitle : "New chat"
        self.navigationItem.backButtonTitle = self.title
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: animated)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
}
