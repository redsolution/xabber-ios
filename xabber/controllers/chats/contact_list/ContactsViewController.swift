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
import RxRealm
import DeepDiff
import CocoaLumberjack
import YubiKit
import MaterialComponents.MDCPalettes

class ContactsViewController: BaseViewController {
    
    class EmptyView: UIView {
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        let centerStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 16
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .title2)
//            if #available(iOS 13.0, *) {
//                label.textColor = .label
//            } else {
                label.textColor = MDCPalette.grey.tint500//.systemGray
//            }//MDCPalette.grey.tint900
            
            return label
        }()
        
        let newChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
            
            return button
        }()
        
        internal var callback: (() -> Void)? = nil
        
        internal func activaateConstraints() {
//            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
        }
        
        open func configure(onCreateChatCallback: @escaping (() -> Void)) {
            if #available(iOS 13.0, *) {
                backgroundColor = .systemBackground
            } else {
                backgroundColor = .white
            }
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(titleLabel)
            centerStack.addArrangedSubview(newChatButton)
            titleLabel.text = "You don't have any contacts".localizeString(id: "you_dont_have_any_contacts_message", arguments: [])
            newChatButton.setTitle("Add someone to your contacts, then send some messages.".localizeString(id: "chat_add_contacts_hint", arguments: []), for: .normal)
            newChatButton.titleLabel?.numberOfLines = 0
            newChatButton.titleLabel?.textAlignment = .center
            activaateConstraints()
            callback = onCreateChatCallback
        }
        
        
        @objc
        internal func onButtonPressed(_ sender: UIButton) {
            callback?()
        }
    }
    
    class FloatingHeader : Equatable {
        
        var section: Int
        var rootView: UIView
        var coloredView: UIView
        var bluredView: UIView
        
        var label: UILabel?
        var topBorder: UIView?
        
        var sectionY: CGFloat = 0
        
        var increaseBlur: CGFloat = 0
        
        static func == (lhs: FloatingHeader, rhs: FloatingHeader) -> Bool {
            return lhs.rootView == rhs.rootView
        }
        
        init(_ section: Int, root: UIView, colored: UIView, blured: UIView) {
            self.section = section
            self.rootView = root
            self.coloredView = colored
            self.bluredView = blured
        }
        
        func update(_ position: CGFloat, diff: CGFloat, topSection: Int) {
            
            let height = self.rootView.frame.height
            let width = self.rootView.frame.width
            
            var setY:CGFloat        = 0          // Default Y
            var setHeight:CGFloat   = 44    // Default Height
            
            if topSection == self.section {
                // This section is top sticky section
                // если не будет косяков при отображении, то будем использовать такое залипание
                setY = (self.section == 0 ? -300 : -44)
                setHeight = (self.section == 0 ? 344 : 88)
    //            setY = -44 // по хорошему, тут надо сделать залипание до верха
    //            setHeight = 88
                
            } else {
                // NOT a top sticky section
                if diff < 20 && diff >= 0 {
                    setY = diff - 20
                    setHeight = height + 20 - diff
                }
            }
    //        print("section \(section) y \(setY) height \(setHeight)")
            self.bluredView.frame = CGRect(x: 0, y: setY, width: width, height: setHeight)
            self.coloredView.frame = CGRect(x: 0, y: setY, width: width, height: setHeight)
            self.topBorder!.frame = CGRect(x: 0, y: setY - 0.5, width: width, height: 0.5)
            self.bluredView.setNeedsDisplay()
            self.coloredView.setNeedsDisplay()
            
        }
        
    }
    
    class Datasource: DiffAware, Equatable, Hashable {
        typealias DiffId = String
        
        var diffId: String {
            get {
                var primary: String = owner
                if let group = group {
                    primary += group
                }
                if let jid = jid {
                    primary += jid
                }
                return primary
            }
        }
        
        enum Kind {
            case group
            case contact
            case collapsed
            case collapsedLast
            case noContact
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.kind == rhs.kind &&
                lhs.owner == rhs.owner &&
                lhs.jid == rhs.jid &&
                lhs.group == rhs.group
        }
        
        var kind: Kind
        var owner: String
        var jid: String?
        var group: String?
        var title: String? = nil
        var subtitle: String? = nil
        var status: ResourceStatus? = nil
        var entity: RosterItemEntity? = nil
        var collapsed: Bool? = nil
        var groupPrimary: String? = nil
        var avatarUrl: String? = nil
        var conversationType: ClientSynchronizationManager.ConversationType = .regular
        
        init(_ kind: Kind, owner: String, jid: String? = nil, group: String? = nil, subtitle: String? = nil, avatarUrl: String? = nil) {
            self.kind = kind
            self.owner = owner
            self.jid = jid
            self.group = group
            self.subtitle = subtitle
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(owner)
            if let jid = jid {
                hasher.combine(jid)
            }
            if let group = group {
                hasher.combine(group)
            }
            if let title = title {
                hasher.combine(title)
            }
        }
        
        static func compareContent(_ a: ContactsViewController.Datasource, _ b: ContactsViewController.Datasource) -> Bool {
            return a.kind == b.kind &&
            a.owner == b.owner &&
            a.jid == b.jid &&
            a.group == b.group &&
            a.title == b.title &&
            a.subtitle == b.subtitle &&
            a.status == b.status &&
            a.entity == b.entity &&
            a.collapsed == b.collapsed &&
            a.avatarUrl == b.avatarUrl
        }
    }
    
    struct EnabledAccount {
        let jid: String
        let isCollapsed: Bool
        let contactsCount: Int
    }
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
        view.register(GroupCell.self, forCellReuseIdentifier: GroupCell.cellName)
        view.register(CollapsedCell.self, forCellReuseIdentifier: CollapsedCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "NoContactCell")
        view.register(NewCollapsedCell.self, forCellReuseIdentifier: NewCollapsedCell.cellName)
        
        return view
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal var isCellTapped: Bool = false
    
    var statusBarView: UIView?
    var blurredEffectView: UIVisualEffectView?
    
    internal var topAccountJid: String = ""
    
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var bag: DisposeBag = DisposeBag()
    internal var accountsBag: DisposeBag = DisposeBag()
    internal var enabledAccounts: BehaviorRelay<[EnabledAccount]> = BehaviorRelay(value: [])
    
    internal var datasource: [[Datasource]] = []
    
    var pinnedAccount: Int = 0
    
    var lastScrollPosition: CGFloat = 0
    var visibleHeaders: [FloatingHeader] = []
    
    var collapsedAccounts: Set<String> = Set<String>()
    
    var showAvatars: Bool = true
    var showOffline: Bool = true
    
    internal let updateQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.contacts.updater",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .never,
            target: nil
        )
        return queue
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = SearchResultsViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search contacts and messages".localizeString(id: "search_contacts_and_messages", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = true
        controller.definesPresentationContext = true

        return controller
    }()
    
    internal let addButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
        button.tintColor = .systemGray
        return button
    }()
    
    internal let accountNavButton: AccountNavButton = {
        let button = AccountNavButton(frame: CGRect(width: 64, height: 40))
        
        return button
    }()
    
    internal let customTitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: UIFont.Weight.medium)
        
        return label
    }()
    
    internal final func updateSectionHeaders(for accounts: [EnabledAccount]) {
        for (index, element) in accounts.enumerated() {
            guard let accountHeaderView = self.tableView.headerView(forSection: index) as? SectionHeader else {
                return
            }
            DispatchQueue.main.async {
                self.tableView.performBatchUpdates {
                    accountHeaderView.configure(collapsed: element.isCollapsed,
                                                title: AccountManager.shared.find(for: element.jid)?.username ?? element.jid,
                                                jid: element.jid,
                                                subtitle: "\(element.contactsCount)",
                                                color: AccountColorManager.shared.palette(for: element.jid).tint700)
                    accountHeaderView.layoutIfNeeded()
                }
            }

        }
    }
    
    private final func mapDataset() -> [[Datasource]] {
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(RosterGroupStorageItem.self)
                .filter("owner IN %@", Array(enabledAccounts.value.compactMap{ return $0.jid }))
                .toArray()

            return enabledAccounts.value.enumerated().compactMap {
                (offset, account) in
                if enabledAccounts.value.count > 1 {
                    if account.isCollapsed {
                        if offset == self.enabledAccounts.value.count - 1 {
                            return[
                                Datasource(.collapsed, owner: account.jid),
                                Datasource(.collapsed, owner: account.jid)
                            ]
                        } else {
                            return[
                                Datasource(.collapsed, owner: account.jid),
                                Datasource(.collapsed, owner: account.jid),
                                Datasource(.collapsedLast, owner: account.jid),
                            ]
                        }
                    }
                }
                let filteredGroups = collection.filter { $0.owner == account.jid }
                if filteredGroups.isEmpty {
                    return [Datasource(.noContact, owner: account.jid)]
                }
                return filteredGroups
                .sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
                .sorted(by: { !$0.isSystemGroup && $1.isSystemGroup })
                .compactMap({ (item) -> [Datasource]? in
                    if item.contacts
                        .filter({ $0.subscribtion != .undefined && !$0.isHidden && !$0.removed})
                        .isEmpty { return nil }
                    var items: [Datasource] = [
                        Datasource(.group,
                            owner: account.jid,
                            jid: nil,
                            group: item.groupName,
                            subtitle: "\(item.contacts.filter({ $0.getPrimaryResource() != nil }).count) / \(item.contacts.count)"
                        )
                    ]
                    items.first?.groupPrimary = item.primary
                    items.first?.collapsed = item.isCollapsed
                    if !item.isCollapsed {
                        items.append(contentsOf: item
                            .contacts
                            .toArray()
                            .sorted(by: { ($0.displayName.lowercased() < $1.displayName.lowercased()) })
                            .compactMap({
                                contact in
                                if contact.subscribtion == .undefined { return nil }
                                if contact.isHidden { return nil }
                                if contact.removed { return nil }
                                let out: Datasource = Datasource(.contact,
                                                                 owner: account.jid,
                                                                 jid: contact.jid,
                                                                 group: item.name)
                                let resource = contact.getPrimaryResource()
                                out.avatarUrl = contact.avatarMinUrl ?? contact.avatarMaxUrl ?? contact.oldschoolAvatarKey
                                out.title = contact.displayName
                                out.status = resource?.status
                                out.entity = resource?.entity
                                out.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                                switch resource?.entity ?? .contact {
                                    case .groupchat:
                                        out.subtitle = "Public group".localizeString(id: "intro_public_group", arguments: [])
                                        out.conversationType = .group
                                    case .privateChat:
                                        out.subtitle = "Private chat".localizeString(id: "intro_private_chat", arguments: [])
                                        out.conversationType = .group
                                    case .incognitoChat:
                                        out.subtitle = "Incognito group".localizeString(id: "intro_incognito_group", arguments: [])
                                        out.conversationType = .group
                                    default:
                                        out.subtitle = contact.jid
                                }
                                if self.showOffline {
                                    return out
                                } else {
                                    return (out.status ?? .offline) == .offline ? nil : out
                                }
                            }
                        ))
                    }
                    return items
                }).reduce([], +)
            }
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [[Change<Datasource>]]) -> ChangesWithIndexPath {
        
        let inserts = changes
            .enumerated()
            .compactMap {
                (offset, item) in
                return item
                    .compactMap { return $0.insert?.index }
                    .compactMap { return IndexPath(row: $0, section: offset) }
            }.reduce([], +)
        
        
        let deletes = changes
            .enumerated()
            .compactMap {
                (offset, item) in
                return item
                    .compactMap { return $0.delete?.index }
                    .compactMap { return IndexPath(row: $0, section: offset) }
            }.reduce([], +)
        
        
        let replaces = changes
            .enumerated()
            .compactMap {
                (offset, item) in
                return item
                    .compactMap { return $0.replace?.index }
                    .compactMap { return IndexPath(row: $0, section: offset) }
            }.reduce([], +)
        
        let moves = changes
            .enumerated()
            .compactMap {
                (offset, item) in
                return item
                    .compactMap { return $0.move }
                    .map {(
                          from: IndexPath(item: $0.fromIndex, section: offset),
                          to: IndexPath(item: $0.toIndex, section: offset)
                        )}
            }.reduce([], +)
        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    public final func initializeDataset() {
        
    }
    
    private func updateEnabledAccounts() {
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            self.enabledAccounts.accept(accounts.compactMap {
                do {
                    let realm = try WRealm.safe()
                    let contactsCount = realm
                        .objects(RosterStorageItem.self)
                        .filter("owner == %@ AND isHidden == false AND removed == false AND subscription_ != %@", $0.jid, "undefined")
                        .count
                    return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: contactsCount)
                } catch {
                    DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                }

                return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: 0)
            })
            self.canUpdateDataset = true
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public final func runDatasetUpdateTask(force: Bool = false) {
        print(#function)
        updateEnabledAccounts()
        preprocessDataset(force)
        postprocessDataset()
    }
    
    private final func preprocessDataset(_ force: Bool = false) {
        
        func transaction(action: (() -> Void)) {
            if force {
                action()
            } else {
                self.updateQueue.sync(execute: action)
            }
        }
        
        if !canUpdateDataset {
            return
        }
                        
        transaction {
            self.canUpdateDataset = false
            let newDataset = self.mapDataset()
            if newDataset.count == 1 {
                if (newDataset.first?.count ?? 0) == 0 {
                    if !self.isEmptyViewShowed.value {
                        self.isEmptyViewShowed.accept(true)
                    }
                } else {
                    if let childsCount = newDataset.first?.count,
                       childsCount == 1,
                       let child = newDataset.first?.first,
                       child.kind == .noContact {
                        if !self.isEmptyViewShowed.value {
                            self.isEmptyViewShowed.accept(true)
                        }
                    } else if self.isEmptyViewShowed.value {
                        self.isEmptyViewShowed.accept(false)
                    }
                }
            } else {
                if self.isEmptyViewShowed.value {
                    self.isEmptyViewShowed.accept(false)
                }
            }

            if newDataset.count == self.datasource.count {
                let changes = newDataset
                    .enumerated()
                    .compactMap {
                        (offset, item) in
                        diff(old: self.datasource[offset], new: item)
                    }
                let indexPaths = self.convertChangeset(changes: changes)
                print(indexPaths.inserts)
                DispatchQueue.main.async {
                    self.apply(changes: indexPaths) {
                        self.datasource = newDataset
                    }
                }
            } else {
                self.datasource = newDataset
                DispatchQueue.main.async {
                    self.tableView.reloadData()
                }
            }
            
        }
    }
    
    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        
//        print("changes", changes.deletes.count, changes.inserts.count, changes.moves.count, changes.replaces.count)
        
        
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.canUpdateDataset = true
            return
        }
        UIView.performWithoutAnimation {
            self.tableView.performBatchUpdates({
                prepare()
                if !changes.deletes.isEmpty {
                    self.tableView.deleteRows(at: changes.deletes, with: .none)
                }
                
                if !changes.inserts.isEmpty {
                    self.tableView.insertRows(at: changes.inserts, with: .none)
                }
                
                if changes.moves.isNotEmpty {
                    changes.moves.forEach {
                        (from, to) in
                        self.tableView.moveRow(at: from, to: to)
                    }
                }
            }, completion: {
                result in
                self.canUpdateDataset = true
                if changes.replaces.isEmpty { return }
                self.tableView.reloadRows(at: changes.replaces, with: .none)
            })
        }
    }
    
    private final func postprocessDataset() {
        updateSectionHeaders(for: self.enabledAccounts.value)
    }
    
    private final func subscribeToDataset() {
        self.bag = DisposeBag()
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND isHidden == false AND removed == false AND subscription_ != %@", Array(self.enabledAccounts.value.compactMap({ return $0.jid })), "")
            Observable.collection(from: collection).debounce(.seconds(1), scheduler: MainScheduler.asyncInstance).subscribe { (results) in
                self.runDatasetUpdateTask()
            } onError: { (error) in
                DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
            }.disposed(by: bag)

        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func subscribe() {
        accountsBag = DisposeBag()
        do {
            let realm = try  WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            self.enabledAccounts.accept(accounts.compactMap {
                do {
                    let realm = try  WRealm.safe()
                    let contactsCount = realm
                        .objects(RosterStorageItem.self)
                        .filter("owner == %@ AND isHidden == false AND removed == false AND subscription_ != %@", $0.jid, "")
                        .count
                    return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: contactsCount)
                } catch {
                    DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                }
                
                return EnabledAccount(jid: $0.jid, isCollapsed: $0.isCollapsed, contactsCount: 0)
            })
            self.updateSectionHeaders(for: self.enabledAccounts.value)
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
            
            Observable
                .collection(from: accounts)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.topAccountJid = item.jid
                        self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                    }
                }).disposed(by: accountsBag)
            
            Observable
                .collection(from: accounts)
//                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .compactMap({ (results) -> [EnabledAccount]? in
                    return results.compactMap({ item -> EnabledAccount? in
                        do {
                            let realm = try  WRealm.safe()
                            let contactsCount = realm
                                .objects(RosterStorageItem.self)
                                .filter("owner == %@ AND isHidden == false AND removed == false AND subscription_ != %@", item.jid, "")
                                .count
                            return EnabledAccount(jid: item.jid, isCollapsed: item.isCollapsed, contactsCount: contactsCount)
                        } catch {
                            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
                        }
                        
                        return EnabledAccount(jid: item.jid, isCollapsed: item.isCollapsed, contactsCount: 0)
                    })
                })
                .subscribe(onNext: { (results) in
                    self.enabledAccounts.accept(results)
                    self.updateSectionHeaders(for: results)
                    UIView.animate(withDuration: 0.1) {
                        self.customTitleLabel.textColor = AccountColorManager.shared.topColor()
                        self.addButton.tintColor = AccountColorManager.shared.topColor()
                    }
                }).disposed(by: accountsBag)
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
        
        enabledAccounts
            .asObservable()
            .subscribe(onNext: { (values) in
                self.showAvatars = SettingManager.shared.get(bool: "roster_showAvatars")
//                self.showOffline = SettingManager.shared.get(bool: "roster_showOfflineContacts")
            })
            .disposed(by: accountsBag)
        
        AccountManager
            .shared
            .connectingUsers
            .asObservable()
            .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                DispatchQueue.main.async {
                    self.updateTitle()
                }
            })
            .disposed(by: accountsBag)
       
        self.subscribeToDataset()
        
        isEmptyViewShowed
            .asObservable()
            .subscribe(onNext: { (value) in
                self.emptyView.isHidden = !value
            })
            .disposed(by: bag)
    }
    
    internal func unsubscribe() {
        accountsBag = DisposeBag()
        bag = DisposeBag()
    }
    
    @objc
    internal func onAccountNavButtonPress(_ sender: UIButton) {
        let vc = SettingsViewController() //AccountInfoViewController()
        vc.jid = self.topAccountJid
        self.navigationController?.pushViewController(vc, animated: true)    }
    
//    private final func configureNavbar() {
//        navigationController?
//            .navigationBar
//            .titleTextAttributes = [NSAttributedString.Key.foregroundColor: AccountColorManager.shared.topColor()]
////        title = "Contacts"
//        self.title = " "
//        self.navigationController?.title = " "
//        addButton.target = self
//        addButton.action = #selector(onAddButtonPress)
//        
//        navigationItem.setRightBarButton(addButton,
//                                         animated: true)
//        let leftButton = UIBarButtonItem(customView: accountNavButton)
//        accountNavButton.addTarget(self, action: #selector(onAccountNavButtonPress), for: .touchUpInside)
//        navigationItem.setLeftBarButton(leftButton, animated: true)
//        customTitleLabel.textColor = AccountColorManager.shared.topColor()
//        self.navigationItem.titleView = customTitleLabel
//        
//        do {
//            let realm = try  WRealm.safe()
//            
//            if let item = realm
//                .objects(AccountStorageItem.self)
//                .filter("enabled == true")
//                .sorted(byKeyPath: "order", ascending: true)
//                .first {
//                self.topAccountJid = item.jid
//                self.accountNavButton.update(jid: item.jid, status: item.resource?.status ?? .offline)
//            }
//            
//        } catch {
//            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
    
    internal let bottomBar: BottomBarView = {
        let view = BottomBarView(frame: .zero)
        
        return view
    }()
    
    @objc
    private func onSidebarButtonTouchUp(_ sender: UIBarButtonItem) {
        self.splitViewController?.show(.primary)
    }
    
    internal let securityButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "security"), style: UIBarButtonItem.Style.plain, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
    @objc
    func showSettings(_ sender: AnyObject) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc)
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: AnyObject) {
        let vc = CreateNewEntityViewController()
        showModal(vc)
    }
    
    internal final func showRegisterYubikeyDialog() {
        if SignatureManager.shared.certificate != nil {
            let vc = YubikeySetupViewController()
            vc.isFromOnboarding = false
            vc.isModal = true
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            SignatureManager.shared.delegate = self
            FeedbackManager.shared.tap()
            if #available(iOS 13.0, *) {
                if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                    YubiKitExternalLocalization.nfcScanAlertMessage = "Register Yubikey for account"
                    YubiKitManager.shared.startNFCConnection()
                    YubiKitManager.shared.delegate = SignatureManager.shared
                    SignatureManager.shared.currentAction = .certificate
                }
            }
        }
    }
    
    @objc
    internal func onRegisterYubikey() {
        showRegisterYubikeyDialog()
    }
    
    internal func configureBars() {
        self.title = "Contacts"
        self.navigationController?.navigationBar.prefersLargeTitles = true
        if #available(iOS 16.0, *) {
            self.navigationItem.preferredSearchBarPlacement = .stacked
        }
        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                let addBarButton = UIBarButtonItem(
                    image: UIImage(systemName: "plus")?
                        .upscale(dimension: 24)
                        .withRenderingMode(.alwaysTemplate),
                    style: .done,
                    target: self,
                    action: #selector(onAddButtonTouchUpInside)
                )
                if CommonConfigManager.shared.config.use_yubikey {
                    self.navigationItem.setRightBarButtonItems([addBarButton, securityButton], animated: true)
                } else {
                    self.navigationItem.setRightBarButtonItems([addBarButton], animated: true)
                }
                let leftBarButton = UIBarButtonItem(customView: accountNavButton)
                self.navigationItem.setLeftBarButton(leftBarButton, animated: true)
                accountNavButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            case .split:
                self.bottomBar.splitViewController = self.splitViewController
                self.view.addSubview(bottomBar)
                self.view.bringSubviewToFront(bottomBar)
                var inputHeight: CGFloat = 49
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
                
                let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                self.bottomBar.updateFrame(to: frame)
                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                self.bottomBar.leftButton.setImage(UIImage(systemName: self.showOffline ? "person.crop.circle" : "person.crop.circle.badge")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
                
                let sidebarButton = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: self, action: #selector(onSidebarButtonTouchUp))
                
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
                }
                self.bottomBar.leftCallback = onLeftBarButtonTouchUp
        }
    }
    
    func onLeftBarButtonTouchUp() {
        self.showOffline = !self.showOffline
//        self.bottomBar.leftButton.setImage(UIImage(systemName: self.showOffline ? "circle" : "circle.fill")?.upscale(dimension: 24), for: .normal)
        
//        if #available(iOS 17.0, *) {
//            if let image = UIImage(systemName: self.showOffline ? "circle" : "circle.fill")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate) {
//                self.bottomBar.leftButton.imageView?.setSymbolImage(image, contentTransition: .replace)
//            }
//        } else {
        self.bottomBar.leftButton.setImage(UIImage(systemName: self.showOffline ? "person.crop.circle" : "person.crop.circle.badge")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
//        }
        
        self.canUpdateDataset = true
        self.runDatasetUpdateTask()
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        bottomBar.updateFrame(to: frame)
    }
    
    internal func updateTitle() {
//        if AccountManager.shared.connectingUsers.value.isNotEmpty {
//            customTitleLabel.text = "Connecting...".localizeString(id: "account_state_connecting", arguments: [])
//            customTitleLabel.sizeToFit()
//            customTitleLabel.layoutIfNeeded()
//            return
//        }
//        customTitleLabel.text = "Contacts".localizeString(id: "contacts", arguments: [])
//        
//        customTitleLabel.sizeToFit()
//        customTitleLabel.layoutIfNeeded()
    }
    
    internal func configure() {
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        self.tableView.tableFooterView = UIView()
        
        emptyView.configure(image: #imageLiteral(resourceName: "buffer160").withRenderingMode(.alwaysTemplate),
                            title: "Contacts list is empty".localizeString(id: "contacts_list_is_empty", arguments: []),
                            subtitle: "Try to add a contact".localizeString(id: "try_to_add_a_contact", arguments: []),
                            buttonTitle: "Add contact".localizeString(id: "application_action_no_contacts", arguments: [])) {
            let vc = CreateNewEntityViewController()
            showModal(vc)
        }
        
        emptyView.isHidden = true
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        configureSearchBar()
        
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
        configureBars()
        subscribe()
        NotifyManager.shared.setLastChats(displayed: false)
        updateTitle()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        if SignatureManager.shared.certificate != nil {
            self.securityButton.tintColor = .systemGreen
        } else {
            self.securityButton.tintColor = .systemRed
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        updateTitle()
        super.viewDidAppear(animated)
//        self.navigationController?.setNavigationBarHidden(true, animated: false)
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = "Contacts".localizeString(id: "contacts", arguments: [])
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribe()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.navigationController?.setNavigationBarHidden(false, animated: true)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
}
