//
//  CallsCategoriesViewController.swift
//  xabber
//
//  Created by Codex on 25.05.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxRealm
import RxSwift
import CocoaLumberjack

class CallsCategoriesViewController: BaseViewController {
    var datasource: [[CallsListCoordinator.CategoryItem]] = []
    var bag: DisposeBag = DisposeBag()
    private var selectedFilter: CallsListFilter = .all
    private let allowsCategoryRowFocus = false

    weak var filterDelegate: CallsControllerFilterProtocol?
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate?

    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
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
            datasource = CallsListCoordinator
                .deriveState(
                    realm: realm,
                    enabledAccounts: LastCallsViewController.enabledAccountJids(in: realm),
                    filter: .all
                )
                .categoriesDatasource
        } catch {
            datasource = []
            DDLogDebug("CallsCategoriesViewController: \(#function). \(error.localizedDescription)")
        }
    }

    func subscribe() {
        bag = DisposeBag()
        loadDatasource()

        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true")
            let calls = realm.objects(MessageStorageItem.self).filter(
                "messageType == %@ AND isDeleted == false",
                MessageStorageItem.MessageDisplayType.call.rawValue
            )

            Observable
                .merge([
                    Observable.collection(from: accounts).map { _ in () },
                    Observable.collection(from: calls).map { _ in () }
                ])
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] in
                    self?.loadDatasource()
                    self?.tableView.reloadData()
                    self?.selectFilter(self?.selectedFilter ?? .all, animated: false, notify: false)
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("CallsCategoriesViewController: \(#function). \(error.localizedDescription)")
        }
    }

    func unsubscribe() {
        bag = DisposeBag()
    }

    public func configure() {
        title = nil
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        applyNavigationAppearance()
        NavigationLargeTitlePolicy.apply(to: self)

        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        tableView.delegate = self
        tableView.dataSource = self
    }

    private func applyNavigationAppearance() {
        guard ContinuousSplitBackgroundExperiment.mode(for: self) == .sharedBackdrop else {
            navigationItem.standardAppearance = nil
            navigationItem.scrollEdgeAppearance = nil
            navigationItem.compactAppearance = nil
            if #available(iOS 15.0, *) {
                navigationItem.compactScrollEdgeAppearance = nil
            }
            return
        }

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

    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
        configureLeadingNavigationItem()
        selectFilter(.all, animated: false, notify: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.applyContinuousSplitInsetGroupedAppearance()
        applyNavigationAppearance()
        NavigationLargeTitlePolicy.apply(to: self)
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
            sidebarButton.accessibilityIdentifier = "calls_sidebar_menu_button"
            navigationItem.setLeftBarButton(sidebarButton, animated: animated)
        } else {
            let backButton = UIBarButtonItem(
                image: imageLiteral("chevron.left"),
                style: .plain,
                target: self,
                action: #selector(onBackButtonTouchUpInside)
            )
            backButton.accessibilityIdentifier = "calls_back_to_chats_button"
            navigationItem.setLeftBarButton(backButton, animated: animated)
        }
    }

    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
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
    }

    @objc
    override func languageChanged() {
        loadDatasource()
        tableView.reloadData()
        selectFilter(selectedFilter, animated: false, notify: false)
    }

    private func removeNotificationObserver() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        unsubscribe()
        removeNotificationObserver()
    }

    func selectFilter(_ filter: CallsListFilter, animated: Bool, notify: Bool) {
        let previousFilter = selectedFilter
        selectedFilter = filter
        syncTableSelection(for: filter, animated: animated)
        reconfigureVisibleCategoryRows(for: [previousFilter, filter])
        if notify {
            filterDelegate?.shouldFilterBy(category: filter.rawValue)
        }
    }

    private func syncTableSelection(for filter: CallsListFilter, animated: Bool) {
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

    private func indexPath(for filter: CallsListFilter) -> IndexPath? {
        for (sectionIndex, section) in datasource.enumerated() {
            if let row = section.firstIndex(where: { !$0.isHeader && $0.key == filter.rawValue }) {
                return IndexPath(row: row, section: sectionIndex)
            }
        }
        return nil
    }

    private func item(at indexPath: IndexPath) -> CallsListCoordinator.CategoryItem? {
        guard datasource.indices.contains(indexPath.section),
              datasource[indexPath.section].indices.contains(indexPath.row) else {
            return nil
        }

        return datasource[indexPath.section][indexPath.row]
    }

    private func isSelectableItem(at indexPath: IndexPath) -> Bool {
        item(at: indexPath)?.isSelectable == true
    }

    private func configureCategoryCell(_ cell: MenuItemTableCell, with item: CallsListCoordinator.CategoryItem) {
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

    private func reconfigureVisibleCategoryRows(for filters: Set<CallsListFilter>) {
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

extension CallsCategoriesViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        datasource.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        datasource[section].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemHeaderTableCell.cellName, for: indexPath) as? MenuItemHeaderTableCell else {
                fatalError()
            }
            cell.configure(title: item.title, subtitle: item.subtitle, icon: item.icon, color: item.color, withCircle: true)
            cell.configureAsInformationalHeader()
            cell.applyContinuousSplitStaticGlassBackground()
            return cell
        }

        guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
            fatalError()
        }

        configureCategoryCell(cell, with: item)

        return cell
    }
}

extension CallsCategoriesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, canFocusRowAt indexPath: IndexPath) -> Bool {
        allowsCategoryRowFocus && isSelectableItem(at: indexPath)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        item(at: indexPath)?.isHeader == true ? UITableView.automaticDimension : 44
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
        selectFilter(CallsListFilter(rawValue: item.key) ?? .all, animated: false, notify: true)
    }
}
