//
//  ContactsCategoryViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 21.07.2025.
//  Copyright © 2025 Igor Boldin. All rights reserved.
//


import Foundation
import UIKit
import RealmSwift
import RxRealm
import RxCocoa
import RxSwift
import CocoaLumberjack

protocol ContactsControllerFilterProtocol {
    func changeOfflineVisibilityState() -> Bool
    func shouldFilterBy(groups: [String])
    func shouldFilterBy(account: String?)
    func shouldFilterBy(category: String?)
}

class ContactsCategoryViewController: BaseViewController {
        
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        var subtitle: String
        var color: UIColor
        var isImportant: Bool
        var value: Int
        var isHeader: Bool
    }
    
    var datasource: [[Datasource]] = []
    var bag: DisposeBag = DisposeBag()
    
    var filterDelegate: ContactsControllerFilterProtocol? = nil
    
    var isGroup: Bool = false
    
    var filteredGroups: Set<String> = Set()
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        view.separatorStyle = .none
        view.backgroundColor = .systemBackground
        view.allowsMultipleSelection = true
        view.allowsSelection = true
        
        return view
    }()
    
    private func loadDatasource() {
        
    }
    
    @objc
    private func onAppear() {
        
    }
    
    func subscribe() {
        self.bag = DisposeBag()
        do {
            if isGroup {
                try self.subscribeGroups()
            } else {
                try self.subscribeContacts()
            }
        } catch {
            DDLogDebug("NotificationsCategoriesViewController: \(#function). \(error.localizedDescription)")
        }
        self.filterDidSelect(category: self.filterCategory)
    }
    
    var filterCategory: String? = nil
    
    
    override func resetState() {
        super.resetState()
        
        self.filteredGroups.removeAll()
//        self.filteredAccounts.removeAll()
        self.tableView
            .indexPathsForSelectedRows?
            .filter({ $0.section == 3 })
            .forEach { self.tableView.deselectRow(at: $0, animated: false) }
    }
    
    func subscribeGroups() throws {
        let realm = try WRealm.safe()
        let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true")
        let jids = accounts.toArray().compactMap({ return $0.jid })
        let contacts = realm
            .objects(RosterStorageItem.self)
            .filter("subscription_ == %@ AND removed == false AND isHidden == false AND isContact == false AND owner IN %@", "both", jids)
            .toArray()
        
        var groupsDatasource: [Datasource] = []
        
        let publicGroups = realm.objects(GroupChatStorageItem.self).filter("owner IN %@ AND privacy_ == %@ AND peerToPeer == false", jids, GroupChatStorageItem.Privacy.publicChat.rawValue).toArray().compactMap({ $0.jid })
        let publicCount = realm.objects(RosterStorageItem.self).filter("subscription_ == %@ AND jid IN %@ AND removed == false AND isHidden == false AND isContact == false", "both", publicGroups).count
        let incognito = realm.objects(GroupChatStorageItem.self).filter("owner IN %@ AND privacy_ == %@ AND peerToPeer == false", jids, GroupChatStorageItem.Privacy.incognito.rawValue).toArray().compactMap({ $0.jid })
        let incognitoCount = realm.objects(RosterStorageItem.self).filter("subscription_ == %@ AND jid IN %@ AND removed == false AND isHidden == false AND isContact == false", "both", incognito).count
        let privateGroups = realm.objects(GroupChatStorageItem.self).filter("owner IN %@ AND peerToPeer == true", jids).compactMap { $0.jid }
        let privateCount = privateGroups.count
        let requests = realm
            .objects(GroupchatInvitesStorageItem.self)
            .filter("owner IN %@ AND isRead == false", jids)
            .toArray()
        let invitationsCount = requests.count
        
        
        
        requests.forEach {
            request in
            let owner = request.owner
            let groupchat = request.groupchat
            AccountManager.shared.find(for: owner)?.action { user, stream in
                user.groupchats.getGroupInfo(stream, groupchat: groupchat)
                user.groupchats.requestUsers(stream, groupchat: groupchat)
            }
        }
        
        let groupsRaw = realm
            .objects(RosterGroupStorageItem.self)
            .filter("owner IN %@ AND isSystemGroup == false", jids)

        groupsRaw.forEach {
            group in
            let count = contacts.filter({ Set($0.groups).contains(group.name) }).count
            groupsDatasource.append(Datasource(title: group.name, icon: "tag", key: group.name, subtitle: "\(count)", color: .tintColor, isImportant: false, value: count, isHeader: false))
        }
        
        self.datasource = [
            [
                Datasource(title: "Groups", icon: "person.2.fill", key: "all", subtitle: "Text about groups, incognito groups and private chats", color: .tintColor, isImportant: false, value: 0, isHeader: true),
            ],
            [
                Datasource(title: "Public Groups", icon: "person.2", key: "public", subtitle: "\(publicCount)", color: .tintColor, isImportant: false, value: publicCount, isHeader: false),
                Datasource(title: "Incognito Groups", icon: "xabber.incognito.variant", key: "incognito", subtitle: "\(incognitoCount)", color: .tintColor, isImportant: false, value: incognitoCount, isHeader: false),
                Datasource(title: "Private Chats", icon: "bubble", key: "private", subtitle: "\(privateCount)", color: .tintColor, isImportant: false, value: privateCount, isHeader: false)
            ],
            [
                Datasource(title: "Invitations", icon: "xabber.invite", key: "invitations", subtitle: "\(invitationsCount)", color: .tintColor, isImportant: true, value: invitationsCount, isHeader: false)
            ],
            groupsDatasource.sorted(by: { $0.value > $1.value })
        ]

        self.tableView.reloadData()
    }
    
    func subscribeContacts() throws {
        
        let realm = try WRealm.safe()
        let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true")

        let jids = accounts.toArray().compactMap({ return $0.jid })
        var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
        ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
        if CommonConfigManager.shared.config.support_jid.isNotEmpty {
            ignoredJids.append(CommonConfigManager.shared.config.support_jid)
        }
        let contacts = realm
            .objects(RosterStorageItem.self)
            .filter("subscription_ IN %@ AND removed == false AND isHidden == false AND isContact == true AND owner IN %@", ["both", "from", "to"], jids)
            .toArray()
        
        let contactsCount = contacts.filter({ ($0.getPrimaryResource()?.entity ?? .contact) == .contact }).count
        var groupsDatasource: [Datasource] = []
        
        let groupsRaw = realm
            .objects(RosterGroupStorageItem.self)
            .filter("owner IN %@ AND isSystemGroup == false", jids)
//            .sorted(byKeyPath: "name")
        
        groupsRaw.forEach {
            group in
            let count = contacts.filter({ Set($0.groups).contains(group.name) }).count
            groupsDatasource.append(Datasource(title: group.name, icon: "tag", key: group.name, subtitle: "\(count)", color: .tintColor, isImportant: false, value: count, isHeader: false))
        }
        
        
        let subscribtionsCount = realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids).count
        let requestsCount = realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "out", ignoredJids).count
        self.datasource = [
            [
                Datasource(title: "Contacts", icon: "person.fill", key: "all", subtitle: "Text about contacts, circles and other", color: .tintColor, isImportant: false, value: 0, isHeader: true),
            ],
            [
                Datasource(title: "Contacts", icon: "person.crop.rectangle.stack", key: "all", subtitle: "\(contactsCount)", color: .tintColor, isImportant: false, value: contactsCount, isHeader: false),
            ],
            [
                Datasource(title: "Contact Requests", icon: "person.text.rectangle", key: "subscribtions", subtitle: "\(subscribtionsCount)", color: .tintColor, isImportant: true, value: subscribtionsCount, isHeader: false),
                Datasource(title: "Outgoing Requests", icon: "xabber.person.plus", key: "requests", subtitle: "\(requestsCount)", color: .tintColor, isImportant: false, value: requestsCount, isHeader: false)
            ],
            groupsDatasource.sorted(by: { $0.value > $1.value })
        ]
        self.tableView.reloadData()
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }
    
    
    
    public func configure() {
        self.title = nil
        
        if CommonConfigManager.shared.config.use_large_title {
            navigationItem.largeTitleDisplayMode = .automatic
        } else {
            navigationItem.largeTitleDisplayMode = .never
        }
        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    @objc
    internal func showOffline(_ sender: UIBarButtonItem) {
        let result = self.filterDelegate?.changeOfflineVisibilityState() ?? false
        if result {
            sender.image = imageLiteral("person")
        } else {
            sender.image = imageLiteral("person.fill")
        }
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: AnyObject) {
        let vc = CreateNewEntityViewController()
        showModal(vc, parent: self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
        let backButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
        self.navigationItem.setLeftBarButton(backButton, animated: false)
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    
    override func observer() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged),
            name: .newLanguageSelected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppear),
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
    }

    @objc
    override func languageChanged() {
//        print("Notification received")
    }

    private func removeNotificationObserer() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        unsubscribe()
        removeNotificationObserer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}


extension ContactsCategoryViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemHeaderTableCell.cellName, for: indexPath) as? MenuItemHeaderTableCell else {
                fatalError()
            }
            
            cell.configure(title: item.title, subtitle: item.subtitle, icon: item.icon, color: item.color, withCircle: true)

            cell.selectionStyle = .none

            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
                fatalError()
            }
            cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: item.isImportant)
            let view = UIView()
            let containerView: UIView = UIView()
            containerView.addSubview(view)
            view.fillSuperviewWithOffset(top: 2, bottom: 2, left: 8, right: 8)
            view.layer.cornerRadius = 16
            view.layer.masksToBounds = true
            view.backgroundColor = AccountColorManager.shared.topPalette().tint50 | AccountColorManager.shared.topPalette().tint900
            cell.selectedBackgroundView = containerView
            
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 3 {
            return "Circles"
        }
        return nil
    }
}

extension ContactsCategoryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            return tableView.estimatedRowHeight
        } else {
            if #available(iOS 26, *) {
                return 52
            } else {
                return 44
            }
        }
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 8
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 3 {
            return tableView.estimatedSectionHeaderHeight
        }
        return 12
    }
    
    private func show(controller vc: UIViewController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.setViewController(vc, for: .supplementary)
//            self.splitViewController?.show(.supplementary)
            self.splitViewController?.hide(.primary)
        } else {
            UIView.performWithoutAnimation {
                self.splitViewController?.setViewController(vc, for: .supplementary)
                self.splitViewController?.show(.supplementary)
                self.splitViewController?.hide(.primary)
            }
        }
        
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        if indexPath.section != 3 {
            let paths = tableView.indexPathsForSelectedRows?.filter({ $0 != indexPath }).filter({ $0.section != 3 })
            paths?.forEach { tableView.deselectRow(at: $0, animated: false) }
        }
        switch indexPath.section {
            case 1:
                self.filterCategory = self.datasource[indexPath.section][indexPath.row].key
                self.filterDelegate?.shouldFilterBy(category: self.datasource[indexPath.section][indexPath.row].key)
                if self.filteredGroups.isNotEmpty {
                    self.filteredGroups.removeAll()
                    self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
                    self.tableView.indexPathsForSelectedRows?.filter({ $0.section == 3 }).forEach {
                        self.tableView.deselectRow(at: $0, animated: false)
                    }
                }
            case 2:
                if filteredGroups.isNotEmpty {
                    self.filteredGroups.removeAll()
                    self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
                }
                self.filterCategory = self.datasource[indexPath.section][indexPath.row].key
                self.filterDelegate?.shouldFilterBy(category: self.datasource[indexPath.section][indexPath.row].key)
                if let selectedItems = tableView.indexPathsForSelectedRows?.filter({$0.section == 3}) {
                    selectedItems.forEach { tableView.deselectRow(at: $0, animated: false) }
                }
            case 3:
                if let selectedItem = tableView.indexPathsForSelectedRows?.filter({ $0.section == 1 }),
                   selectedItem.isEmpty {
                    tableView.selectRow(at: IndexPath(row: 0, section: 1), animated: false, scrollPosition: .none)
                    self.filterCategory = self.datasource[1][0].key
                    self.filterDelegate?.shouldFilterBy(category: self.datasource[1][0].key)
                }
                if let selectedItems = tableView.indexPathsForSelectedRows?.filter({$0.section == 2}) {
                    selectedItems.forEach { tableView.deselectRow(at: $0, animated: false) }
                }
                self.filteredGroups.insert(self.datasource[indexPath.section][indexPath.row].key)
                self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
            default:
                break
        }
    }
    
    func tableView(_ tableView: UITableView, willDeselectRowAt indexPath: IndexPath) -> IndexPath? {
        if indexPath.section < 3 {
            return nil
        }
        return indexPath
    }
    
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        switch indexPath.section {
            case 1, 2:
                self.filterDelegate?.shouldFilterBy(category: nil)
            case 3:
                self.filteredGroups.remove(self.datasource[indexPath.section][indexPath.row].key)
                self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
            default:
                break
        }
    }
    
}

extension ContactsCategoryViewController: ContactsCategoryDelegate {
    func filterDidSelect(category: String?) {
        if let category = category {
            if self.filterCategory != category {
                self.filterCategory = category
            }
            self.tableView.indexPathsForSelectedRows?.filter({ $0.section < 3 }).forEach {
                self.tableView.deselectRow(at: $0, animated: false)
            }
            var indexPath: IndexPath? = nil
            self.datasource.enumerated().forEach {
                (section, item) in
                if let row = item.firstIndex(where: { $0.key == category }) {
                    indexPath = IndexPath(row: row, section: section)
                }
            }
            if let indexPath = indexPath {
                self.tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
            }
        } else {
            
        }
    }
    
    func filterDidSelect(account: String?) {
        
    }
    
    func filterDidSelect(groups: [String]) {
        
    }
    
    
}
