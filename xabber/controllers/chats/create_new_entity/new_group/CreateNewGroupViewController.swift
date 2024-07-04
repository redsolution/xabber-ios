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
import RxSwift
import RxCocoa
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import TOInsetGroupedTableView

class CreateNewGroupViewController: BaseViewController {
    
    enum CellKind {
        case common
        case server
        case account
        case privacy
        case membership
        case index
        case description
    }
    
    open var createIncognitoGroup: Bool = false
        
    internal var sectionHeaders: [String?] = []
    
    internal var sectionFooter: [String?] = []
    
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var name: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var onCreate: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var account: [String: String] = [:]
    internal var localpart: String? = nil
    internal var canGenerateLocalpart: Bool = true
    internal var server: [String: String] = ["type": "default", "label": "xmppdev01.xabber.com", "value": "xmppdev01.xabber.com"]
    internal var privacy: [String: String] = ["type": "default", "label": "Public", "value": "public"]
    internal var index: [String: String] = ["type": "default", "label": "Local", "value": "local"]
    internal var membership: [String: String] = ["type": "default", "label": "Open", "value": "open"]
    internal var descr: String = ""
    
//    internal var creatingGroupJid: String? = nil
    internal var creatingOwnerJid: String? = nil
    
    internal var datasource: [[CellKind]] = []
        
    internal let saveButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Create".localizeString(id: "create", arguments: []),
                                     style: .plain, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
    
    internal let createIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(DescriptionCell.self, forCellReuseIdentifier: DescriptionCell.cellName)
        view.register(ItemCell.self, forCellReuseIdentifier: ItemCell.cellName)
        view.register(JidSelectCell.self, forCellReuseIdentifier: JidSelectCell.cellName)
        view.register(GroupInfoCell.self, forCellReuseIdentifier: GroupInfoCell.cellName)
        
        return view
    }()
    
    internal func subscribe() {
        bag = DisposeBag()
        name
            .asObservable()
            .subscribe(onNext: { (value) in
                if value != nil {
                    if !self.saveButton.isEnabled {
                        UIView.animate(withDuration: 0.33) {
                            self.saveButton.isEnabled = true
                        }
                    }
                } else {
                    if self.saveButton.isEnabled {
                        UIView.animate(withDuration: 0.33) {
                            self.saveButton.isEnabled = false
                        }
                    }
                }
                if self.canGenerateLocalpart {
                    if AccountManager.shared.users.count > 1 {
                        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 2)], with: .none)
                    } else {
                        self.tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
                    }
                }
            })
            .disposed(by: bag)
        
        saveButton
            .rx
            .tap
            .subscribe(onNext: { _ in
                self.onSave()
            })
            .disposed(by: bag)
        
//        inSaveMode
//            .asObservable()
////            .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
//            .subscribe(onNext: { (value) in
//
//            }).disposed(by: bag)
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func configureNavbar() {
        if createIncognitoGroup {
            title = "New incognito group".localizeString(id: "groupchats_new_incognito_group", arguments: [])
        } else {
            title = "New group".localizeString(id: "groupchats_new_group", arguments: [])
        }
        navigationItem.setRightBarButton(saveButton, animated: true)
    }
    
    internal func configureDatasource() {
        account = ["type": "default", "label": AccountManager.shared.users.first?.jid ?? "", "value": AccountManager.shared.users.first?.jid ?? ""]
        if AccountManager.shared.users.count > 1 {
            account = ["type": "default", "label": AccountManager.shared.users.first?.jid ?? "", "value": AccountManager.shared.users.first?.jid ?? ""]
            sectionHeaders = [
                "Select XMPP account".localizeString(id: "select_xmpp_account", arguments: []),
                "Group name".localizeString(id: "groupchat_name", arguments: []),
                "Group XMPP ID".localizeString(id: "groupchats_group_xmpp_id", arguments: [])
            ]
            
            sectionFooter = [
                "Group chat will be created by this account"
                    .localizeString(id: "groupchats_group_chat_will_be_created", arguments: []),
                "For example: Developer`s chat"
                    .localizeString(id: "groupchats_example_chat_name", arguments: []),
                "You can select custom server, which support groups."
                    .localizeString(id: "groupchats_select_custom_server_hint", arguments: [])
            ]
            
            datasource = [[.account],
                          [.common],
                          [.server]]
        } else {
            sectionHeaders = [
                nil,
                "Group XMPP ID".localizeString(id: "groupchats_group_xmpp_id", arguments: []),
            ]
            
            sectionFooter = [
                "For example: Developer`s chat"
                    .localizeString(id: "groupchats_example_chat_name", arguments: []),
                "You can select custom server, which support groups."
                    .localizeString(id: "groupchats_select_custom_server_hint", arguments: []),
            ]
            
            datasource = [[.common],
                          [.server]]
        }
    }
    
    internal func configure() {
        tableView.frame = view.bounds
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        configureNavbar()
        configureDatasource()
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
