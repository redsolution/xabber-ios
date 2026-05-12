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
    
    var filteredAccounts: Set<String> = Set()
    var filteredGroups: Set<String> = Set()
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
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
        do {
            let realm = try WRealm.safe()
            datasource = ContactsListCoordinator.deriveState(
                realm: realm,
                state: currentFilterState(),
                datasourceBuilder: { _, _ in [] }
            ).categoryDatasource
        } catch {
            datasource = []
            DDLogDebug("ContactsCategoryViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    private func onAppear() {
        
    }
    
    func subscribe() {
        self.bag = DisposeBag()
        loadDatasource()
        subscribeToCollections()
        self.filterDidSelect(category: self.filterCategory)
        self.filterDidSelect(groups: Array(self.filteredGroups))
    }
    
    var filterCategory: String? = nil
    
    
    override func resetState() {
        super.resetState()
        
        self.filteredGroups.removeAll()
        self.tableView
            .indexPathsForSelectedRows?
            .filter({ $0.section == 3 })
            .forEach { self.tableView.deselectRow(at: $0, animated: false) }
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }

    private func currentFilterState() -> ContactsFilterState {
        ContactsFilterState(
            category: filterCategory,
            filteredAccounts: filteredAccounts,
            filteredGroups: filteredGroups,
            showOffline: true,
            isGroup: isGroup
        )
    }

    private func reloadDataAndSelection() {
        loadDatasource()
        tableView.reloadData()
        filterDidSelect(category: filterCategory)
        filterDidSelect(groups: Array(filteredGroups))
    }

    private func subscribeToCollections() {
        do {
            let realm = try WRealm.safe()
            let accountsCollection = realm.objects(AccountStorageItem.self).filter("enabled == true")
            let rosterCollection = realm.objects(RosterStorageItem.self)
            let groupsCollection = realm.objects(RosterGroupStorageItem.self).filter("isSystemGroup == false")

            var invalidations: [Observable<Void>] = [
                Observable.collection(from: accountsCollection).map { _ in () },
                Observable.collection(from: rosterCollection).map { _ in () },
                Observable.collection(from: groupsCollection).map { _ in () }
            ]

            if isGroup {
                let invitesCollection = realm.objects(GroupchatInvitesStorageItem.self)
                let groupchatCollection = realm.objects(GroupChatStorageItem.self)
                let groupUsersCollection = realm.objects(GroupchatUserStorageItem.self).filter("isHidden == false")
                invalidations.append(Observable.collection(from: invitesCollection).map { _ in () })
                invalidations.append(Observable.collection(from: groupchatCollection).map { _ in () })
                invalidations.append(Observable.collection(from: groupUsersCollection).map { _ in () })
            }

            Observable.merge(invalidations)
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] in
                    self?.reloadDataAndSelection()
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("ContactsCategoryViewController: \(#function). \(error.localizedDescription)")
        }
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
        tableView.allowsMultipleSelectionDuringEditing = false
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
            let selectionView = UIView()
            selectionView.backgroundColor = AccountColorManager.shared.topPalette().tint50 | AccountColorManager.shared.topPalette().tint900
            selectionView.layer.cornerRadius = 16
            selectionView.layer.masksToBounds = true

            let containerView = UIView()
            containerView.addSubview(selectionView)
            selectionView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                selectionView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 2),
                selectionView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -2),
                selectionView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                selectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8)
            ])
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
                if self.filteredGroups.isNotEmpty {
                    self.filteredGroups.removeAll()
                    self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
                    self.tableView.indexPathsForSelectedRows?.filter({ $0.section == 3 }).forEach {
                        self.tableView.deselectRow(at: $0, animated: false)
                    }
                }
                self.filterDelegate?.shouldFilterBy(category: self.datasource[indexPath.section][indexPath.row].key)
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
            self.filterCategory = nil
            self.tableView.indexPathsForSelectedRows?.filter({ $0.section < 3 }).forEach {
                self.tableView.deselectRow(at: $0, animated: false)
            }
        }
    }
    
    func filterDidSelect(account: String?) {
        if let account = account {
            filteredAccounts = [account]
        } else {
            filteredAccounts.removeAll()
        }
        reloadDataAndSelection()
    }
    
    func filterDidSelect(groups: [String]) {
        filteredGroups = Set(groups)
        tableView.indexPathsForSelectedRows?.filter({ $0.section == 3 }).forEach {
            tableView.deselectRow(at: $0, animated: false)
        }
        guard datasource.indices.contains(3) else { return }
        datasource[3].enumerated().forEach { row, item in
            guard filteredGroups.contains(item.key) else { return }
            tableView.selectRow(at: IndexPath(row: row, section: 3), animated: false, scrollPosition: .none)
        }
    }
    
    
}
