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
        var isSelectable: Bool = true
    }
    
    var datasource: [[Datasource]] = []
    var bag: DisposeBag = DisposeBag()
    
    var filterDelegate: ContactsControllerFilterProtocol? = nil
    
    var isGroup: Bool = false
    
    var filteredAccounts: Set<String> = Set()
    var filteredGroups: Set<String> = Set()
    private var suppressNativeDeselectionCallbacks = false
    private let allowsCategoryRowFocus = false
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        view.separatorStyle = .none
        view.allowsMultipleSelection = false
        view.allowsSelection = true
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 44
        view.applyContinuousSplitInsetGroupedAppearance()
        
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
        clearNativeSelection()
        reconfigureVisibleCategoryRows()
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
            isGroup: isGroup,
            searchQuery: nil
        )
    }

    private func reloadDataAndSelection() {
        loadDatasource()
        tableView.reloadData()
        filterDidSelect(category: filterCategory)
        filterDidSelect(groups: Array(filteredGroups))
    }

    private func clearNativeSelection() {
        guard let selectedRows = tableView.indexPathsForSelectedRows, selectedRows.isNotEmpty else {
            return
        }

        suppressNativeDeselectionCallbacks = true
        selectedRows.forEach { tableView.deselectRow(at: $0, animated: false) }
        suppressNativeDeselectionCallbacks = false
    }

    private func reconfigureVisibleCategoryRows() {
        clearNativeSelection()
        (tableView.indexPathsForVisibleRows ?? []).forEach { indexPath in
            guard datasource.indices.contains(indexPath.section),
                  datasource[indexPath.section].indices.contains(indexPath.row),
                  let cell = tableView.cellForRow(at: indexPath) as? MenuItemTableCell else {
                return
            }

            configureCategoryCell(cell, with: datasource[indexPath.section][indexPath.row], at: indexPath)
        }
    }

    private func configureCategoryCell(_ cell: MenuItemTableCell, with item: Datasource, at indexPath: IndexPath) {
        cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: item.isImportant)
        cell.applyPlainGroupedSystemBackground(
            selectedColor: AccountSelectionHighlightStyle.tint50(owner: nil),
            isSelected: isCategoryItemSelected(item, at: indexPath)
        )
        cell.layer.cornerRadius = 0
        cell.layer.masksToBounds = false
        cell.layer.borderWidth = 0
        cell.layer.shadowOpacity = 0
    }

    private func isSectionOneCategorySelected() -> Bool {
        guard datasource.indices.contains(1),
              let filterCategory else {
            return false
        }

        return datasource[1].contains { $0.key == filterCategory }
    }

    private func item(at indexPath: IndexPath) -> Datasource? {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].indices.contains(indexPath.row) else {
            return nil
        }

        return datasource[indexPath.section][indexPath.row]
    }

    private func isSelectableItem(at indexPath: IndexPath) -> Bool {
        item(at: indexPath)?.isSelectable == true
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
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        applyNavigationAppearance()
        
        NavigationLargeTitlePolicy.apply(to: self)
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelectionDuringEditing = false
    }

    private func applyNavigationAppearance() {
        NativeSectionNavigationBarPolicy.apply(to: self)
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
        configureLeadingNavigationItem()
    }

    internal func configureLeadingNavigationItem(
        forRegularWidth: Bool = UIDevice.current.userInterfaceIdiom == .pad,
        animated: Bool = false
    ) {
        let prefix = isGroup ? "groups" : "contacts"
        if forRegularWidth {
            let sidebarButton = UIBarButtonItem(
                image: imageLiteral("sidebar.left"),
                style: .plain,
                target: self,
                action: #selector(onSidebarButtonTouchUpInside)
            )
            sidebarButton.accessibilityIdentifier = "\(prefix)_sidebar_menu_button"
            navigationItem.setLeftBarButton(sidebarButton, animated: animated)
        } else {
            let backButton = UIBarButtonItem(
                image: imageLiteral("chevron.left"),
                style: .plain,
                target: self,
                action: #selector(onBackButtonTouchUpInside)
            )
            backButton.accessibilityIdentifier = "\(prefix)_back_to_chats_button"
            navigationItem.setLeftBarButton(backButton, animated: animated)
        }
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }

    @objc
    private final func onSidebarButtonTouchUpInside(_ sender: UIBarButtonItem) {
        splitViewController?.show(.primary)
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
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.applyContinuousSplitInsetGroupedAppearance()
        applyNavigationAppearance()
        NavigationLargeTitlePolicy.apply(to: self)
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

            cell.configureAsInformationalHeader()
            cell.applyContinuousSplitStaticGlassBackground()

            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
                fatalError()
            }
            configureCategoryCell(cell, with: item, at: indexPath)
            
            return cell
        }
    }

    private func isCategoryItemSelected(_ item: Datasource, at indexPath: IndexPath) -> Bool {
        if indexPath.section == 3 {
            return filteredGroups.contains(item.key)
        }
        return filterCategory == item.key
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 3 {
            return "Circles"
        }
        return nil
    }
}

extension ContactsCategoryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        allowsCategoryRowFocus && isSelectableItem(at: indexPath)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let item = item(at: indexPath) else {
            return 44
        }
        if item.isHeader {
            return UITableView.automaticDimension
        } else {
            if #available(iOS 26, *) {
                return 52
            } else {
                return 44
            }
        }
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

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        isSelectableItem(at: indexPath)
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        isSelectableItem(at: indexPath) ? indexPath : nil
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = item(at: indexPath), item.isSelectable else {
            tableView.deselectRow(at: indexPath, animated: false)
            return
        }

        defer {
            clearNativeSelection()
            reconfigureVisibleCategoryRows()
        }

        switch indexPath.section {
            case 1:
                self.filterCategory = item.key
                if self.filteredGroups.isNotEmpty {
                    self.filteredGroups.removeAll()
                    self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
                }
                self.filterDelegate?.shouldFilterBy(category: item.key)
            case 2:
                if filteredGroups.isNotEmpty {
                    self.filteredGroups.removeAll()
                    self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
                }
                self.filterCategory = item.key
                self.filterDelegate?.shouldFilterBy(category: item.key)
            case 3:
                if !isSectionOneCategorySelected(),
                   datasource.indices.contains(1),
                   let allContactsItem = datasource[1].first {
                    self.filterCategory = allContactsItem.key
                    self.filterDelegate?.shouldFilterBy(category: allContactsItem.key)
                }
                if self.filteredGroups.contains(item.key) {
                    self.filteredGroups.remove(item.key)
                } else {
                    self.filteredGroups.insert(item.key)
                }
                self.filterDelegate?.shouldFilterBy(groups: Array(self.filteredGroups))
            default:
                break
        }
    }
    
    func tableView(_ tableView: UITableView, willDeselectRowAt indexPath: IndexPath) -> IndexPath? {
        isSelectableItem(at: indexPath) ? indexPath : nil
    }
    
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard !suppressNativeDeselectionCallbacks else {
            return
        }

        guard isSelectableItem(at: indexPath) else {
            return
        }

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
        filterCategory = category
        reconfigureVisibleCategoryRows()
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
        reconfigureVisibleCategoryRows()
    }
    
    
}

extension ContactsCategoryViewController: LeftMenuRootNavigationChromeRefreshable {
    func refreshLeftMenuRootNavigationChromeAfterModalDismiss() {
        configureLeadingNavigationItem(forRegularWidth: true, animated: false)
    }
}
