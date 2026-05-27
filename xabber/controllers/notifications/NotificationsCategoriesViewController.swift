//
//  NotificationsCategoriesViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 23.05.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxRealm
import RxCocoa
import RxSwift
import CocoaLumberjack

class NotificationsCategoriesViewController: BaseViewController {
    var datasource: [[NotificationsListCoordinator.CategoryItem]] = []
    var bag: DisposeBag = DisposeBag()
    private var selectedFilter: NotificationsListViewController.Filter = .all
    private let allowsCategoryRowFocus = false

    var filterDelegate: NotificationsControllerFilterProtocol? = nil
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil

    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        view.separatorStyle = .none
        view.allowsMultipleSelection = false
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 44
        view.applyContinuousSplitInsetGroupedAppearance()
        
        return view
    }()
    
    private func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            let owners = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap(\.jid)
            datasource = NotificationsListCoordinator
                .deriveState(
                    realm: realm,
                    owners: owners,
                    filter: .all,
                    filterAccount: nil,
                    headerBuilder: { _ in nil },
                    listMapper: { _, _ in [] }
                )
                .categoriesDatasource
        } catch {
            datasource = []
            DDLogDebug("NotificationsCategoriesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    private func onAppear() {
        
    }
    
    
    func subscribe() {
        self.bag = DisposeBag()
        loadDatasource()
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true")
            Observable.collection(from: accounts).subscribe { results in
                self.loadDatasource()
                self.tableView.reloadData()
                self.selectFilter(self.selectedFilter, animated: false, notify: false)
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

        } catch {
            DDLogDebug("NotificationsCategoriesViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }
    
    
    
    public func configure() {
        self.title = nil
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        applyNavigationAppearance()
        if CommonConfigManager.shared.config.use_large_title {
            navigationItem.largeTitleDisplayMode = .automatic
        } else {
            navigationItem.largeTitleDisplayMode = .never
        }
        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        tableView.delegate = self
        tableView.dataSource = self
//        bottomBar.configure()
//        self.view.addSubview(bottomBar)
//        self.view.bringSubviewToFront(bottomBar)
//        var inputHeight: CGFloat = 80
//        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
//            inputHeight += bottomInset
//        }
//        
//        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
//        bottomBar.frame = frame
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
        configureLeadingNavigationItem()
        selectFilter(.all, animated: false, notify: true)
//        self.splitViewController?.displayModeButtonVisibility = .never
    }

    private func applyNavigationAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        if #available(iOS 15.0, *) {
            navigationItem.compactScrollEdgeAppearance = appearance
        }
    }

    internal func configureLeadingNavigationItem(
        forRegularWidth: Bool = UIDevice.current.userInterfaceIdiom == .pad,
        animated: Bool = false
    ) {
        if forRegularWidth {
            let sidebarButton = UIBarButtonItem(
                image: imageLiteral("sidebar.left"),
                style: .plain,
                target: self,
                action: #selector(onSidebarButtonTouchUpInside)
            )
            sidebarButton.accessibilityIdentifier = "notifications_sidebar_menu_button"
            navigationItem.setLeftBarButton(sidebarButton, animated: animated)
        } else {
            let backButton = UIBarButtonItem(
                image: imageLiteral("chevron.left"),
                style: .plain,
                target: self,
                action: #selector(onBackButtonTouchUpInside)
            )
            backButton.accessibilityIdentifier = "notifications_back_to_chats_button"
            navigationItem.setLeftBarButton(backButton, animated: animated)
        }
    }
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }

    @objc
    private final func onSidebarButtonTouchUpInside(_ sender: UIBarButtonItem) {
        splitViewController?.show(.primary)
    }
    
    override func observer() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageChanged),
                                               name: .newLanguageSelected,
                                               object: nil)
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(onAppear),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)
    }

    @objc
    override func languageChanged() {
        loadDatasource()
        tableView.reloadData()
        selectFilter(selectedFilter, animated: false, notify: false)
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

    func selectFilter(_ filter: NotificationsListViewController.Filter, animated: Bool, notify: Bool) {
        let previousFilter = selectedFilter
        selectedFilter = filter
        syncTableSelection(for: filter, animated: animated)
        reconfigureVisibleCategoryRows(for: [previousFilter, filter])
        if notify && (previousFilter != filter || filter == .all) {
            filterDelegate?.shouldFilterBy(category: filter.rawValue)
        }
    }

    private func syncTableSelection(for filter: NotificationsListViewController.Filter, animated: Bool) {
        let selectedIndexPath = indexPath(for: filter)
        tableView.indexPathsForSelectedRows?
            .filter { indexPath in
                selectedIndexPath.map { indexPath != $0 } ?? true
            }
            .forEach { tableView.deselectRow(at: $0, animated: false) }

        guard let selectedIndexPath else {
            return
        }

        tableView.selectRow(at: selectedIndexPath, animated: animated, scrollPosition: .none)
    }

    private func indexPath(for filter: NotificationsListViewController.Filter) -> IndexPath? {
        for (sectionIndex, section) in datasource.enumerated() {
            if let row = section.firstIndex(where: { !$0.isHeader && $0.key == filter.rawValue }) {
                return IndexPath(row: row, section: sectionIndex)
            }
        }
        return nil
    }

    private func item(at indexPath: IndexPath) -> NotificationsListCoordinator.CategoryItem? {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].indices.contains(indexPath.row) else {
            return nil
        }

        return datasource[indexPath.section][indexPath.row]
    }

    private func isSelectableItem(at indexPath: IndexPath) -> Bool {
        item(at: indexPath)?.isSelectable == true
    }

    private func configureCategoryCell(
        _ cell: MenuItemTableCell,
        with item: NotificationsListCoordinator.CategoryItem
    ) {
        cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: true)
        cell.imageView?.tintColor = item.color
        cell.applyPlainGroupedSystemBackground(
            selectedColor: AccountSelectionHighlightStyle.tint50(owner: nil),
            isSelected: item.key == selectedFilter.rawValue
        )
        cell.layer.cornerRadius = 0
        cell.layer.masksToBounds = false
        cell.layer.borderWidth = 0
        cell.layer.shadowOpacity = 0
    }

    private func reconfigureVisibleCategoryRows(for filters: Set<NotificationsListViewController.Filter>) {
        filters
            .compactMap { indexPath(for: $0) }
            .forEach { indexPath in
                guard let cell = tableView.cellForRow(at: indexPath) as? MenuItemTableCell else {
                    return
                }
                configureCategoryCell(cell, with: datasource[indexPath.section][indexPath.row])
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
    }
}


extension NotificationsCategoriesViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    
//    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
//        var configuration = UIListContentConfiguration.sidebarHeader()
////        configuration.textProperties.
//        switch section {
//            case 0: configuration.text = ""
//            case 1: configuration.text = "Accounts"
//            default: break
//        }
//        
////        configuration.textProperties.font = UIFont.preferredFont(forTextStyle: .title2)
////        configuration.textProperties.color = .label
////        configuration.textProperties.transform = .capitalized
//        
//        (view as? UITableViewHeaderFooterView)?.contentConfiguration = configuration
//    }
//    
//    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
//        switch section {
//            case 0: return ""
//            case 1: return "Accounts"
//            default: return nil
//        }
//    }
    
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
            
            configureCategoryCell(cell, with: item)
            
            return cell
        }
        
    }
}

extension NotificationsCategoriesViewController: UITableViewDelegate {
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
            return 44
        }
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        isSelectableItem(at: indexPath)
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        isSelectableItem(at: indexPath) ? indexPath : nil
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
        guard let item = item(at: indexPath), item.isSelectable else {
            tableView.deselectRow(at: indexPath, animated: false)
            return
        }
        selectFilter(NotificationsListViewController.Filter(rawValue: item.key) ?? .all, animated: false, notify: true)
    }
}
