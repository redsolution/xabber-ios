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
import RxCocoa
import DeepDiff
import CocoaLumberjack

class GroupchatInviteViewController: BaseViewController {
    
    class Item: Hashable {
        
        static func == (lhs: Item, rhs: Item) -> Bool {
            return lhs.jid == rhs.jid
        }
        
        var username: String
        var jid: String
        var status: ResourceStatus
        var collapsed: Bool
        
        init(_ username: String, jid: String = "", status: ResourceStatus = .offline, collapsed: Bool) {
            self.username = username
            self.jid = jid
            self.status = status
            self.collapsed = collapsed
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(jid)
        }
    }
    
    class Datasource: Hashable {
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.name == rhs.name
        }
        
        var name: String
        var collapsed: Bool = false
        var childs: [Item]
        
        init(name: String) {
            self.name = name
            self.childs = []
        }
        
        func add(_ item: Item) {
            if !childs.contains(item) {
                childs.append(item)
            }
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }
    }
    
//    internal var jid: String = ""
//    internal var owner: String = ""
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var datasource: [Datasource] = []
    
    internal var inSaveMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var collapsedGroups: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var selectedGroups: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var selectedJids: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    internal var diffSelectedJids: Set<String> = Set<String>()
    
    internal var inviteErrorMessage: String? = nil
    internal var invitedJids: Set<String> = Set<String>()
    internal var conflictJids: Set<String> = Set<String>()
    
    internal var invitedJidsCount: Int = 0
    internal var errorJidsCount: Int = 0
    
//    internal var contacts: Results<RosterStorageItem>? = nil
    
    
    internal let cancelButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                     style: .plain, target: nil, action: nil)
        
        return button
    }()
    
    internal let inviteButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Invite".localizeString(id: "groupchat_invite", arguments: []),
                                     style: .done, target: nil, action: nil)
        
        button.isEnabled = false
        
        return button
    }()
    
    internal let saveIndicator: UIBarButtonItem = {
        let indicator = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.gray)
        indicator.startAnimating()
        let button = UIBarButtonItem(customView: indicator)
        
        return button
    }()
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
//        view.remembersLastFocusedIndexPath = true
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "UITableViewCell")
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
        view.register(HeaderView.self, forHeaderFooterViewReuseIdentifier: HeaderView.headerView)
        
        view.tableFooterView = UIView()
        
        return view
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = InviteSearchViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search".localizeString(id: "search", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.obscuresBackgroundDuringPresentation = true
        controller.dimsBackgroundDuringPresentation = true
        controller.hidesNavigationBarDuringPresentation = false
        controller.hidesBottomBarWhenPushed = false
        controller.searchBar.searchFieldBackgroundPositionAdjustment = UIOffset(horizontal: 0, vertical: 4)
        
        return controller
    }()
    
    internal func load() {
        do {
            let realm = try WRealm.safe()
//            contacts = realm
//                .objects(RosterStorageItem.self)
//                .filter("owner == %@ AND isHidden == %@ AND removed == %@ AND subscription_ == %@", owner, false, false, "both")
//            formDatasource(contacts!)
            formDatasource(groups: realm.objects(RosterGroupStorageItem.self).filter("owner == %@", owner))
        } catch {
            DDLogDebug("GroupchatInviteViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func formDatasource(groups: Results<RosterGroupStorageItem>) {
        datasource = groups
            .toArray()
            .filter { $0.name != RosterGroupStorageItem.notInRosterGroupName }
            .sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
            .sorted(by: { !$0.isSystemGroup && $1.isSystemGroup })
            .compactMap { (group) -> Datasource? in
                let item = Datasource(name: group.groupName)
                
                group.contacts
                    .toArray()
                    .filter{ ($0.getPrimaryResource()?.entity ?? .contact) == .contact && !$0.removed && !$0.isHidden && [.to, .from, .both].contains($0.subscribtion) }
                    .sorted(by: {$0.displayName.lowercased() < $1.displayName.lowercased()})
                    .forEach { item.add(Item($0.displayName,
                                             jid: $0.jid,
                                             status: $0.getPrimaryResource()?.status ?? .offline,
                                             collapsed: collapsedGroups.value.contains(group.name))) }
                
                return item
            }
        self.tableView.reloadData()
    }
    
    internal func formDatasourceOld(_ dataset: Results<RosterStorageItem>) {
        var groups: Set<Datasource> = Set<Datasource>()
        dataset.filter({ $0.getPrimaryResource()?.entity == .contact || $0.getPrimaryResource() == nil }).forEach {
            for item in $0.groups {
                if let group = groups.first(where: { $0.name == item }) {
                    group.add(Item($0.displayName,
                                   jid: $0.jid,
                                   status: $0.getPrimaryResource()?.status ?? .offline,
                                   collapsed: collapsedGroups.value.contains(group.name)))
                } else {
                    let group = Datasource(name: item)
                    group.add(Item($0.displayName,
                                   jid: $0.jid,
                                   status: $0.getPrimaryResource()?.status ?? .offline,
                                   collapsed: collapsedGroups.value.contains(group.name)))
                    groups.insert(group)
                }
            }
        }
        groups.forEach {  $0.childs = $0.childs.sorted(by: { $0.username < $1.username })}
        datasource = Array(groups.sorted(by: { $0.name < $1.name }))
        self.tableView.reloadData()
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        
        
//        if contacts != nil {
//            self.formDatasource(contacts!)
//            Observable
//                .collection(from: contacts!)
//                .debounce(0.33, scheduler: MainScheduler.asyncInstance)
//                .subscribe(onNext: { (results) in
//                    self.formDatasource(results)
//                })
//                .disposed(by: bag)
//        }
        
        cancelButton
            .rx
            .tap
            .asObservable()
            .subscribe(onNext: { _ in
                self.onCancel()
            })
            .disposed(by: bag)
        
        inviteButton
            .rx
            .tap
            .asObservable()
            .subscribe(onNext: { _ in
                self.onInvite()
            })
            .disposed(by: bag)
        
        inSaveMode
            .asObservable()
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    self.tableView.isUserInteractionEnabled = !value
                    if value {
                        self.navigationItem.setRightBarButton(self.saveIndicator, animated: true)
                    } else {
                        self.navigationItem.setRightBarButton(self.inviteButton, animated: true)
                    }
                }
            })
            .disposed(by: bag)
        
//        collapsedGroups
//            .asObservable()
//            .subscribe(onNext: { (value) in
////                DispatchQueue.main.async {
//                    let indexSet = IndexSet(value.compactMap { item in
//                        return self.datasource.firstIndex(where: { $0.name == item })})
//                    self.tableView.reloadSections(indexSet, with: .automatic)
////                }
//            })
//            .disposed(by: bag)
        
        selectedJids
            .asObservable()
            .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                DispatchQueue.main.async {
                    UIView.animate(withDuration: 0.33) {
                        if value.isEmpty {
                            if self.inviteButton.isEnabled {
                                self.inviteButton.isEnabled = false
                            }
                        } else {
                            if !self.inviteButton.isEnabled {
                                self.inviteButton.isEnabled = true
                            }
                        }
                    }
                }
                
//                self.tableView.reloadData()
            })
            .disposed(by: bag)
        
//        select
        
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configureNavbar() {
        title = "Invite users".localizeString(id: "groupchat_invite_users", arguments: [])
        navigationItem.setLeftBarButton(cancelButton, animated: true)
        navigationItem.setRightBarButton(inviteButton, animated: true)
//        navigationItem.setRightBarButton(editButtonItem, animated: true)
    }
    
    open func configure(jid: String, owner: String) {
        self.jid = jid
        self.owner = owner
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        activateConstraints()
        configureNavbar()
        load()
        tableView.isEditing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.isUserInteractionEnabled = true
        configureSearchBar()
//        tableView.selected
//        tableView.allowsSelectionDuringEditing = true
//        tableView.allowsSelection = true
//        tableView.select
//        tableView.edi
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
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
        subscribe()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}

