//
//  NotificationsListViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 18.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import XMPPFramework.XMPPJID

class NotificationsListViewController: SimpleBaseViewController {
    
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
            backgroundColor = .systemBackground
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(titleLabel)
//            centerStack.addArrangedSubview(newChatButton)
            titleLabel.text = "You don't have any notifications"
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
    
    let emptyView: EmptyView = {
        let view = EmptyView()
        
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
//        view.backgroundColor = .systemBackground
        view.separatorStyle = .singleLine
        
        view.register(NotificationItemCell.self, forCellReuseIdentifier: NotificationItemCell.cellName)
        view.register(NotificationsSubscribtionsListViewController.ContactItemCell.self, forCellReuseIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        
        view.allowsSelection = true
        
        return view
    }()
        
    class Datasource {
        let title: String
        let key: String
        var childs: [DatasourceChild]
        
        init(title: String, key: String, childs: [DatasourceChild]) {
            self.title = title
            self.key = key
            self.childs = childs
        }
    }
    
    class DatasourceChild {
        var primary: String
        var category: XMPPNotificationsManager.Category
        var owner: String
        var jid: String
        var title: NSAttributedString
        var message: NSAttributedString?
        var key: String?
        var date: Date
        var avatarUrl: String?
        var badgeIcon: String
        var isRead: Bool
        var isHeader: Bool
        
        init(primary: String, category: XMPPNotificationsManager.Category, owner: String, jid: String, title: NSAttributedString, message: NSAttributedString? = nil, key: String? = nil, date: Date, avatarUrl: String? = nil, badgeIcon: String, isRead: Bool, isHeader: Bool) {
            self.primary = primary
            self.category = category
            self.owner = owner
            self.jid = jid
            self.title = title
            self.message = message
            self.key = key
            self.date = date
            self.avatarUrl = avatarUrl
            self.badgeIcon = badgeIcon
            self.isRead = isRead
            self.isHeader = isHeader
        }
    }
    
    var datasource: [Datasource] = []
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
        
        self.emptyView.isHidden = !self.emptyScreenShowObserver.value
        self.view.addSubview(self.emptyView)
        self.emptyView.fillSuperview()
        self.view.bringSubviewToFront(self.emptyView)
    }
    
    override func configure() {
        super.configure()
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.title = nil
        } else {
            self.title = "Notifications"
        }
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.emptyView.configure { }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        self.getAndMapDatasource()
    }
    
    var emptyScreenShowObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    enum Filter: String {
        case all = "all"
        case security = "security"
        case mentions = "mentions"
        case info = "info"
    }
    
    var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .all)
    var filterAccount: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var filterMenu: UIMenu = UIMenu()
    
    func configureBars() {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .done, target: self, action: nil)
        var childs: [UIMenuElement] = [
            UIAction(
                title: "All",
                image: imageLiteral("bell"),
                identifier: .none,
                discoverabilityTitle: "Displays all notifications",
                attributes: [],
                state: filter.value == .all ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.all.rawValue)
                }),
            UIAction(
                title: "Security",
                image: imageLiteral("shield"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .security ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.security.rawValue)
                }),
            UIAction(
                title: "Mentions",
                image: imageLiteral("at"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .mentions ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.mentions.rawValue)
                }),
        ]
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
                if UIDevice.current.userInterfaceIdiom == .pad {
                    childs = []
                }
        }
        do {
            let realm = try WRealm.safe()
            let accounts: [UIMenuElement] = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .toArray()
                .compactMap ({
                    item in
                    return UIAction(
                        title: item.username,
                        image: imageLiteral("person.crop.circle"),
                        identifier: .none,
                        discoverabilityTitle: nil,
                        attributes: [],
                        state: filter.value == .info ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(account: item.jid)
                        }
                    )
                })
            
            if accounts.count > 1 {
                childs.append(contentsOf: accounts)
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        
        filterMenu = UIMenu(options: [.singleSelection], children: childs)
        
        button.menu = filterMenu
        
        var readAllNotificationsButton = UIBarButtonItem(image: imageLiteral("checkmark"), style: .plain, target: self, action: #selector(onReadAllNotifications))
        if childs.count <= 1 {
            self.navigationItem.setRightBarButtonItems([readAllNotificationsButton], animated: true)
        } else {
            self.navigationItem.setRightBarButtonItems([button, readAllNotificationsButton], animated: true)
        }
    }
        
    @objc
    private func onReadAllNotifications(_ sender: UIBarButtonItem) {
        print("read")
        self.datasource.forEach {
            $0.childs.forEach {
                $0.isRead = true
            }
        }
        self.tableView.visibleCells.forEach {
            ($0 as? NotificationsSubscribtionsListViewController.ContactItemCell)?.updateReadState(true, animated: true)
            ($0 as? NotificationItemCell)?.updateReadState(true, animated: true)
        }
        do {
            let realm = try WRealm.safe()
            var jids: [String] = []
            if let filteredJid = filterAccount.value {
                jids = [filteredJid]
            } else {
                jids = AccountManager.shared.users.map { $0.jid }
            }
            var categories: [String] = []
            switch self.filter.value {
                case .all:
                    categories = [
                        XMPPNotificationsManager.Category.device.rawValue,
                        XMPPNotificationsManager.Category.mention.rawValue,
                        XMPPNotificationsManager.Category.info.rawValue
                    ]
                case .security:
                    categories = [
                        XMPPNotificationsManager.Category.device.rawValue
                    ]
                case .mentions:
                    categories = [
                        XMPPNotificationsManager.Category.mention.rawValue,
                    ]
                case .info:
                    categories = [
                        XMPPNotificationsManager.Category.info.rawValue,
                    ]
            }
            let allNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("shouldShow == true AND owner IN %@ AND category_ IN %@", jids, categories).sorted(byKeyPath: "date", ascending: false)
            try realm.write {
                allNotifications.forEach { $0.isRead = true }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func getAndMapDatasource() {
        
        do {
            var jids: [String] = []
            if let filteredJid = filterAccount.value {
                jids = [filteredJid]
            } else {
                jids = AccountManager.shared.users.map { $0.jid }
            }
            var categories: [String] = []
            switch self.filter.value {
                case .all:
                    categories = [
                        XMPPNotificationsManager.Category.device.rawValue,
                        XMPPNotificationsManager.Category.mention.rawValue,
                        XMPPNotificationsManager.Category.info.rawValue
                    ]
                case .security:
                    categories = [
                        XMPPNotificationsManager.Category.device.rawValue
                    ]
                case .mentions:
                    categories = [
                        XMPPNotificationsManager.Category.mention.rawValue,
                    ]
                case .info:
                    categories = [
                        XMPPNotificationsManager.Category.info.rawValue,
                    ]
            }
            let realm = try WRealm.safe()
            let allNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("shouldShow == true AND owner IN %@ AND category_ IN %@", jids, categories).sorted(byKeyPath: "date", ascending: false)
//            let contactNotifications = realm
//                .objects(NotificationStorageItem.self)
//                .filter(
//                    "shouldShow == true AND owner IN %@ AND category_ == %@",
//                    jids,
//                    XMPPNotificationsManager.Category.contact.rawValue
//                )
            
            if self.filter.value == .all {
                
                self.datasource = [
                    //mapResult(contactNotifications, title: "Subscription requests", key: "subscribtion_requests")
                ]
            } else {
                self.datasource = []
            }
            switch self.filter.value {
                    
                case .all:
                    self.datasource = []
                case .security:
                    self.datasource = [
                        Datasource(title: "", key: "", childs: [
                            DatasourceChild(
                                primary: "security_item_header",
                                category: .device,
                                owner: "",
                                jid: "",
                                title: NSAttributedString(string: "Security"),
                                message: NSAttributedString(string: "Notifications about new logins, device changes, and activity on your account."),
                                key: nil,
                                date: Date(),
                                avatarUrl: nil,
                                badgeIcon: "custom.shield.pattern.checkered.square.fill",
                                isRead: true,
                                isHeader: true
                            )
                        ])
                    ]
                case .mentions:
                    self.datasource = [
                        Datasource(title: "", key: "", childs: [
                            DatasourceChild(
                                primary: "mention_item_header",
                                category: .device,
                                owner: "",
                                jid: "",
                                title: NSAttributedString(string: "Mentions"),
                                message: NSAttributedString(string: "Alerts when you are tagged in conversations, helping you stay aware of relevant discussions."),
                                key: nil,
                                date: Date(),
                                avatarUrl: nil,
                                badgeIcon: "custom.at.square.fill",
                                isRead: true,
                                isHeader: true
                            )
                        ])
                    ]
                case .info:
                    self.datasource = [
                        Datasource(title: "", key: "", childs: [
                            DatasourceChild(
                                primary: "info_item_header",
                                category: .device,
                                owner: "",
                                jid: "",
                                title: NSAttributedString(string: "Information"),
                                message: NSAttributedString(string: "Updates, tips, and system messages from server operators and various contacts to keep you informed about features, maintenance, and app-related news."),
                                key: nil,
                                date: Date(),
                                avatarUrl: nil,
                                badgeIcon: "info.square.fill",
                                isRead: true,
                                isHeader: true
                            )
                        ])
                    ]
            }
            mapResultByDate(allNotifications).forEach {
                self.datasource.append($0)
            }
            
            self.datasource = self.datasource.compactMap { return $0.childs.isNotEmpty ? $0 : nil }
            
            self.emptyScreenShowObserver.accept(self.datasource.isEmpty)
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func notificationItemToDatasourceChild(_ item: NotificationStorageItem) -> DatasourceChild? {
        switch item.category {
            case .contact:
                return nil
            case .device:
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: "New login", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: " to server ", attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: item.associatedJid ?? item.jid, attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                var message: NSAttributedString? = nil
                if let text = item.text {
                    message = NSAttributedString(string: text, attributes: [
                        .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: UIColor.secondaryLabel
                    ])
                }
                return DatasourceChild(
                    primary: item.primary,
                    category: item.category,
                    owner: item.owner,
                    jid: item.jid,
                    title: title,
                    message: message,
                    key: item.jid,
                    date: item.date,
                    avatarUrl: nil,
                    badgeIcon: "badge-circle-big-security",
                    isRead: item.isRead,
                    isHeader: false
                )
            case .mention:
                return nil
//                let title = NSMutableAttributedString()
//                title.append(NSAttributedString(string: "Juliet", attributes: [
//                    .font: UIFont.boldSystemFont(ofSize: 14),
//                    .foregroundColor: UIColor.label
//                ]))
//                title.append(NSAttributedString(string: " mentioned you in ", attributes: [
//                    .font: UIFont.systemFont(ofSize: 14),
//                    .foregroundColor: UIColor.label
//                ]))
//                title.append(NSAttributedString(string: "mychat@capulet.it: ", attributes: [
//                    .font: UIFont.boldSystemFont(ofSize: 14),
//                    .foregroundColor: UIColor.label
//                ]))
//                title.append(NSAttributedString(string: "... the clock strook nine when I did send the nurse...", attributes: [
//                    .font: UIFont.italicSystemFont(ofSize: 14),
//                    .foregroundColor: UIColor.secondaryLabel
//                ]))
//                return DatasourceChild(
//                    primary: item.primary,
//                    category: item.category,
//                    owner: item.owner,
//                    jid: item.jid,
//                    title: title,
//                    message: nil,
//                    key: item.jid,
//                    date: item.date,
//                    avatarUrl: nil,
//                    badgeIcon: "at.circle.fill",
//                    isRead: item.isRead
//                )
                
            case .info:
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: "New information message", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: " from server ", attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: "\(item.associatedJid ?? item.jid): ", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: UIColor.label
                ]))
                if let message = item.metadata?["text"] as? String {
                    title.append(NSAttributedString(string: message, attributes: [
                        .font: UIFont.italicSystemFont(ofSize: 14),
                        .foregroundColor: UIColor.secondaryLabel
                    ]))
                }
                return DatasourceChild(
                    primary: item.primary,
                    category: item.category,
                    owner: item.owner,
                    jid: item.jid,
                    title: title,
                    message: nil,
                    key: item.jid,
                    date: item.date,
                    avatarUrl: nil,
                    badgeIcon: "badge-circle-big-info",
                    isRead: item.isRead,
                    isHeader: false
                )
        }
    }
    
    private func mapResultByDate(_ results: Results<NotificationStorageItem>) -> [Datasource] {
        var currentDate: String? = nil
        
        var out: [Datasource] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        dateFormatter.doesRelativeDateFormatting = true
        results.forEach {
            item in
            let calendarDate = Calendar.current.dateComponents([.day, .year, .month], from: item.date)
            let newDate = "\(calendarDate.day ?? 0).\(calendarDate.month ?? 0).\(calendarDate.year ?? 0)"
            if newDate != currentDate {
                currentDate = newDate
                let child = notificationItemToDatasourceChild(item)
                
                if let child = child {
                    let title = dateFormatter.string(from: item.date)//string(from: item.date)
//                    if NSCalendar.current.isDateInToday(item.date) {
//                        title = "Today"
//                    } else if NSCalendar.current.isDateInYesterday(item.date) {
//                        title = "Yesterday"
//                    }
                    out.append(Datasource(
                            title: title,
                            key: "notifications",
                            childs: [child]
                        )
                    )
                }
            } else {
                let child = notificationItemToDatasourceChild(item)
                
                if let child = child {
                    out.last?.childs.append(child)
                }
            }
        }
        
        return out
    }
    
    private func mapResult(_ results: Results<NotificationStorageItem>, title: String, key: String) -> Datasource {
        return Datasource(title: title, key: key, childs: results.compactMap({
            return notificationItemToDatasourceChild($0)
        }))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
//        if CommonConfigManager.shared.config.use_large_title {
//            self.navigationItem.largeTitleDisplayMode = .automatic
//        } else {
            self.navigationItem.largeTitleDisplayMode = .never
//        }
        self.navigationController?.navigationBar.prefersLargeTitles = false//CommonConfigManager.shared.config.use_large_title
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                let sidebarButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
                
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
                }
        }
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.configureBars()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        AccountManager.shared.users.forEach {
            user in
            if user.xmppStream.isAuthenticated {
                user.action { user, stream in
                    user.notifications.update(stream)
//                    user.notifications.readAll(stream)
                }
            }
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AccountManager.shared.users.forEach {
            user in
            if user.xmppStream.isAuthenticated {
                user.action { user, stream in
//                    user.notifications.update(stream)
                    user.notifications.readAll(stream)
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AccountManager.shared.users.forEach {
            user in
            if user.xmppStream.isAuthenticated {
                user.action { user, stream in
                    user.notifications.readAll(stream)
                }
            }
        }
    }
    
    override func subscribe() {
        super.subscribe()
        
        let jids = AccountManager.shared.users.map { $0.jid }
        
        do {
            let realm = try WRealm.safe()
            let collectionObserver = realm.objects(NotificationStorageItem.self).filter("owner IN %@ AND shouldShow == true", jids)
            self.filter
                .asObservable()
                .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
                .subscribe { value in
//                    switch value {
//                        case .all:
//                            self.title = "All"
//                        case .security:
//                            self.title = "Security"
//                        case .mentions:
//                            self.title = "Mentions"
//                        case .info:
//                            self.title = "Information"
//                    }
                    self.loadDatasource()
                    self.tableView.reloadData()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.filterAccount
                .asObservable()
                .debounce(.milliseconds(5), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { _ in
                    self.loadDatasource()
                    self.tableView.reloadData()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { _ in
                    self.loadDatasource()
                    self.tableView.reloadData()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.emptyScreenShowObserver
                .asObservable()
                .debounce(.milliseconds(1), scheduler: MainScheduler.asyncInstance)
                .subscribe { value in
                    self.emptyView.isHidden = !value
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
}

extension NotificationsListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
//    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
//        if section == 0 && self.filter.value != .all {
//            return
//        }
//        var configuration = UIListContentConfiguration.sidebarHeader()
//
//        configuration.text = self.datasource[section].title
//        
//        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 6, bottom: 0, trailing: 6)
//        
//        (view as? UITableViewHeaderFooterView)?.contentConfiguration = configuration
//    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 && self.filter.value != .all {
            return nil
        }
        return self.datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return nil
    }
    
//    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
//        if section == 0 && self.filter.value != .all {
//            return nil
//        }
//        let frame = CGRect(
//            origin: CGPoint(
//                x: 0,
//                y: 0
//            ),
//            size: CGSize(
//                width: self.view.bounds.width,
//                height: 34
//            )
//        )
//        let view = ChatViewController.FloatDateView(frame: frame)
//        view.configure(NSAttributedString(
//            string: self.datasource[section].title,
//            attributes: [
//                .font: UIFont.preferredFont(forTextStyle: .caption1),
//                .foregroundColor: UIColor.black,
//            ])
//        )
//        view.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.1)
//        return view
//    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 34
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.datasource[section].key == "contact" {
            return self.datasource[section].childs.count > 2 ? 2 : self.datasource[section].childs.count
        }
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = self.datasource[indexPath.section]
        let item = section.childs[indexPath.row]
        if item.isHeader {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemHeaderTableCell.cellName, for: indexPath) as? MenuItemHeaderTableCell else {
                fatalError()
            }
            
            cell.configure(title: item.title.string, subtitle: item.message?.string ?? "", icon: item.badgeIcon, color: .tintColor)

            cell.selectionStyle = .none

            return cell
        }
        switch section.key {
            case "subscribtion_requests":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName, for: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell else {
                    fatalError()
                }
                
                cell.selectionStyle = .none
                cell.configure(
                    owner: item.owner,
                    username: item.title,
                    jid: item.jid,
                    message: item.message,
                    icon: item.badgeIcon,
                    avatarUrl: item.avatarUrl,
                    uuid: item.key ?? "",
                    isRead: item.isRead
                )
                
                cell.addButtonAction = self.addButtonAction
                cell.declineButtonAction = self.declineButtonAction
                
//                let view = UIView()
//                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
//                cell.selectedBackgroundView = view
                
                cell.accessoryType = .detailButton
                
                return cell
            case "notifications":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationItemCell.cellName, for: indexPath) as? NotificationItemCell else {
                    fatalError()
                }
                cell.selectionStyle = .none
                cell.configure(
                    jid: item.jid,
                    owner: item.owner,
                    avatarUrl: item.avatarUrl,
                    icon: item.badgeIcon,
                    title: item.title,
                    message: item.message,
                    date: item.date,
                    isRead: item.isRead
                )
                
//                let view = UIView()
//                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
//                cell.selectedBackgroundView = view
                
                cell.accessoryType = .none
                
                return cell
            default:
                fatalError()
        }
    }
}

extension NotificationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return tableView.estimatedRowHeight
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        let section = self.datasource[indexPath.section]
        section.childs[indexPath.row].isRead = true
        let primary = section.childs[indexPath.row].primary
        DispatchQueue.global(qos: .utility).async {
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary)?.isRead = true
                }
            } catch {
                DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            }
        }
        
        switch section.key {
            case "subscribtion_requests":
                if let cell = tableView.cellForRow(at: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell {
                    cell.updateReadState(true, animated: true)
                }
            case "notifications":
                if let cell = tableView.cellForRow(at: indexPath) as? NotificationItemCell {
                    cell.updateReadState(true, animated: true)
                }
            default:
                break
        }
        return indexPath
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let section = self.datasource[indexPath.section]
        let item = section.childs[indexPath.row]
//        section.childs[indexPath.row].isRead = true
        switch section.key {
            case "subscribtion_requests":
                let vc = ContactInfoViewController()
                vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                vc.owner = item.owner
                vc.jid = item.jid
                showModal(vc, parent: self)
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            case "notifications":
                switch item.category {
                    case .device:
                        let vc = DevicesListViewController()
                        vc.configure(for: item.owner)
                        showModal(vc, parent: self)
                    default:
                        break
                }
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            default:
                break
        }
    }
}

extension NotificationsListViewController {
    public func addButtonAction(_ jid: String, _ owner: String, _ uuid: String) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.subscribe(stream, jid: jid)
            user.presences.subscribed(stream, jid: jid, storePreaproved: false)
            user.roster.setContact(stream, jid: jid, nickname: nil, groups: [], callback: nil)
        })
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uuid)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func declineButtonAction(_ jid: String, _ owner: String, _ uuid: String) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.unsubscribed(stream, jid: jid)
        })
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uuid)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
}

extension NotificationsListViewController: NotificationsControllerFilterProtocol {
    func shouldFilterBy(account: String?) {
        if let account = account {
            self.filterAccount.accept(self.filterAccount.value == account ? nil : account)
        } else {
            self.filterAccount.accept(nil)
        }
    }
    
    func shouldFilterBy(category: String?) {
        if category == "all" {
            self.filter.accept(.all)
        } else if let category = category {
            let filterValue = Filter(rawValue: category) ?? .all
            self.filter.accept(self.filter.value == filterValue ? .all : filterValue)
        } else {
            self.filter.accept(.all)
        }
    }
}

extension NotificationsListViewController {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let index = indexPath.row
//        let index = showArchivedSection.value ? indexPath.row - 1 : indexPath.row
//        if index < 0 { return nil }
        
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive,
                                              title: "Delete".localizeString(id: "delete", arguments: [])) {
            (action, view, handler) in
            
            let item = self.datasource[indexPath.section].childs[indexPath.row]
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary) {
                        realm.delete(instance)
                    }
                }
            } catch {
                DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            }
            handler(true)
        }
        
        let readAction = UIContextualAction(style: .destructive,
                                              title: "Read".localizeString(id: "action_mark_as_read", arguments: [])) {
            (action, view, handler) in
            let item = self.datasource[indexPath.section].childs[indexPath.row]
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary) {
                        instance.isRead = true
                    }
                }
            } catch {
                DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            }
            handler(true)
        }
        
        deleteAction.image = imageLiteral( "trash")
        readAction.image = imageLiteral("checkmark")
        deleteAction.backgroundColor = .systemRed
        readAction.backgroundColor = .systemBlue
        if item.isRead {
            return UISwipeActionsConfiguration(actions: [deleteAction])
        } else {
            return UISwipeActionsConfiguration(actions: [deleteAction, readAction])
        }
    }
}
