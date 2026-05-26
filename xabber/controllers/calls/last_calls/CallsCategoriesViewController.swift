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

    override func viewDidLoad() {
        super.viewDidLoad()
        observer()
        configure()
        subscribe()
        let backButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
        navigationItem.setLeftBarButton(backButton, animated: true)
        selectFilter(.all, animated: false, notify: true)
    }

    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
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
            cell.selectionStyle = .none
            cell.applyContinuousSplitGlassBackground()
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
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        datasource[indexPath.section][indexPath.row].isHeader ? UITableView.automaticDimension : 44
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        guard !item.isHeader else {
            tableView.deselectRow(at: indexPath, animated: false)
            return
        }
        let key = item.key
        selectFilter(CallsListFilter(rawValue: key) ?? .all, animated: false, notify: true)
    }
}
