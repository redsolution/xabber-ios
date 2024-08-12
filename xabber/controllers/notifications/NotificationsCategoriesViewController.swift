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

class NotificationsCategoriesViewController: UIViewController {
        
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        var subtitle: String
        var color: UIColor
    }
    
    var datasource: [[Datasource]] = []
    var bag: DisposeBag = DisposeBag()
    
    var filterDelegate: NotificationsControllerFilterProtocol? = nil
    
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
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
                    
                    let accountsDatsource: [Datasource] = results.compactMap {
                        let notificationsCount = notifications.filter({ $0.owner == $0.jid }).count
                        return Datasource(title: $0.username, icon: "person.crop.circle", key: $0.jid, subtitle: "\(notificationsCount)", color: AccountColorManager.shared.palette(for: $0.jid).tint500)
                    }
                    let securityCount = notifications.filter({ $0.category == .device }).count
                    let mentionsCount = notifications.filter({ $0.category == .mention }).count
                    let infoCount = notifications.filter({ $0.category == .info }).count
                    self.datasource = [[
                        Datasource(title: "All", icon: "bell", key: "all", subtitle: "\(notifications.count)", color: .tintColor),
                        Datasource(title: "Security", icon: "shield", key: "security", subtitle: "\(securityCount)", color: .tintColor),
                        Datasource(title: "Mentions", icon: "at", key: "mentions", subtitle: "\(mentionsCount)", color: .tintColor),
                        Datasource(title: "Information", icon: "info", key: "info", subtitle: "\(mentionsCount)", color: .tintColor)
                    ],accountsDatsource]
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
        self.title = "Notifications"
        navigationController?.navigationBar.prefersLargeTitles = true
        
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
    }
    
    private func observer() {
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
    func languageChanged() {
        print("Notification received")
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
    
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        var configuration = UIListContentConfiguration.sidebarHeader()
//        configuration.textProperties.
        switch section {
            case 0: configuration.text = "Filters"
            case 1: configuration.text = "Accounts"
            default: break
        }
        
//        configuration.textProperties.font = UIFont.preferredFont(forTextStyle: .title2)
//        configuration.textProperties.color = .label
//        configuration.textProperties.transform = .capitalized
        
        (view as? UITableViewHeaderFooterView)?.contentConfiguration = configuration
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
            case 0: return "Filters"
            case 1: return "Accounts"
            default: return nil
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "tablecell")
        
        cell.textLabel?.text = datasource[indexPath.section][indexPath.row].title
        cell.imageView?.image = imageLiteral(datasource[indexPath.section][indexPath.row].icon, dimension: 24)
        cell.imageView?.tintColor = datasource[indexPath.section][indexPath.row].color
//        cell.selectionStyle =
        cell.backgroundColor = .clear
        let text = datasource[indexPath.section][indexPath.row].subtitle
        
        cell.detailTextLabel?.text = text == "0" ? "" : text
        
        let view = UIView()
        view.layer.cornerRadius = 16
        view.layer.masksToBounds = true
        
        view.backgroundColor = AccountColorManager.shared.topPalette().tint50 | AccountColorManager.shared.topPalette().tint900
        
        cell.selectedBackgroundView = view
        
        return cell
    }
    
    
}

extension NotificationsCategoriesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return tableView.estimatedRowHeight
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
        if tableView.indexPathsForSelectedRows?.filter({ $0.section == indexPath.section}).isNotEmpty ?? false {
            guard let selectedInSection = tableView.indexPathsForSelectedRows?.filter({ $0.row != indexPath.row && $0.section == indexPath.section }) else {
                return
            }
            selectedInSection.forEach { tableView.deselectRow(at: $0, animated: false) }
        }
        switch indexPath.section {
            case 0:
                self.filterDelegate?.shouldFilterBy(category: self.datasource[indexPath.section][indexPath.row].key)
            case 1:
                self.filterDelegate?.shouldFilterBy(account: self.datasource[indexPath.section][indexPath.row].key)
            default:
                break
        }
    }
}
