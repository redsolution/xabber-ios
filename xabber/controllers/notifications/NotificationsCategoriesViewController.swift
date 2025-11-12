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
        
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        var subtitle: String
        var color: UIColor
        var isHeader: Bool
    }
    
    var datasource: [[Datasource]] = []
    var bag: DisposeBag = DisposeBag()
    
    var filterDelegate: NotificationsControllerFilterProtocol? = nil
    
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        view.separatorStyle = .none
        view.backgroundColor = .systemBackground
        view.allowsMultipleSelection = true
        
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
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true")
            Observable.collection(from: accounts).subscribe { results in
                
                do {
                    let realm = try WRealm.safe()
                    let jids = results.toArray().compactMap({ return $0.jid })
                    let notifications = realm.objects(NotificationStorageItem.self).filter("isRead == false AND shouldShow == true AND owner IN %@", jids).toArray()
                    
//                    let accountsDatsource: [Datasource] = results.compactMap {
//                        let notificationsCount = notifications.filter({ $0.owner == $0.jid }).count
//                        return Datasource(title: $0.username, icon: "person.crop.circle", key: $0.jid, subtitle: "\(notificationsCount)", color: AccountColorManager.shared.palette(for: $0.jid).tint500)
//                    }
                    let securityCount = notifications.filter({ $0.category == .device }).count
                    let mentionsCount = notifications.filter({ $0.category == .mention }).count
                    let infoCount = notifications.filter({ $0.category == .info }).count
                    self.datasource = [
                        [
                            Datasource(title: "Notifications", icon: "bell.fill", key: "all", subtitle: "Manage security alerts, information updates, mentions, and other notifications.", color: .tintColor, isHeader: true),
                        ],
                        [
                            Datasource(title: "Notifications", icon: "bell", key: "all", subtitle: "\(notifications.count)", color: .tintColor, isHeader: false),
                        ],
                        [
                            Datasource(title: "Security", icon: "checkerboard.shield", key: "security", subtitle: "\(securityCount)", color: .tintColor, isHeader: false),
                            Datasource(title: "Information", icon: "info.circle", key: "info", subtitle: "\(infoCount)", color: .tintColor, isHeader: false),
                            Datasource(title: "Mentions", icon: "at", key: "mentions", subtitle: "\(mentionsCount)", color: .tintColor, isHeader: false),
                        ]
                    ]
                } catch {
                    DDLogDebug("NotificationsCategoriesViewController: \(#function). \(error.localizedDescription)")
                }
                
                
                
                self.tableView.reloadData()
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
        self.title = nil//"Notifications"
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
        let backButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
        self.navigationItem.setLeftBarButton(backButton, animated: true)
        self.tableView.selectRow(at: IndexPath(row: 0, section: 1), animated: true, scrollPosition: .none)
        self.filterDelegate?.shouldFilterBy(category: "all")
//        self.splitViewController?.displayModeButtonVisibility = .never
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
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

            cell.selectionStyle = .none

            return cell
        } else {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
                fatalError()
            }
            
            cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: true)

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
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return UIView()
    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return nil
    }
}

extension NotificationsCategoriesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section][indexPath.row]
        if item.isHeader {
            return tableView.estimatedRowHeight
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
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
//        if tableView.indexPathsForSelectedRows?.filter({ $0.section == indexPath.section}).isNotEmpty ?? false {
//            guard let selectedInSection = tableView.indexPathsForSelectedRows?.filter({ $0.row != indexPath.row && $0.section == indexPath.section }) else {
//                return
//            }
//            selectedInSection.forEach { tableView.deselectRow(at: $0, animated: false) }
//        }
        let paths = tableView.indexPathsForSelectedRows?.filter({ $0 != indexPath }).filter({ $0.section != 3 })
        paths?.forEach { tableView.deselectRow(at: $0, animated: false) }
        
        
        switch indexPath.section {
            case 1, 2:
                self.filterDelegate?.shouldFilterBy(category: self.datasource[indexPath.section][indexPath.row].key)
            case 3:
                self.filterDelegate?.shouldFilterBy(account: self.datasource[indexPath.section][indexPath.row].key)
            default:
                break
        }
    }
}
