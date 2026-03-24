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

enum NotificationsSupport {
    struct Counters {
        let total: Int
        let security: Int
        let mentions: Int
        let info: Int
    }

    static func rosterKey(owner: String, jid: String) -> String {
        [owner, jid].prp()
    }

    static func categoryStrings(for filter: NotificationsListViewController.Filter) -> [String] {
        switch filter {
        case .all:
            return [
                XMPPNotificationsManager.Category.device.rawValue,
                XMPPNotificationsManager.Category.mention.rawValue,
                XMPPNotificationsManager.Category.info.rawValue,
            ]
        case .security:
            return [XMPPNotificationsManager.Category.device.rawValue]
        case .mentions:
            return [XMPPNotificationsManager.Category.mention.rawValue]
        case .info:
            return [XMPPNotificationsManager.Category.info.rawValue]
        }
    }

    static func notifications(
        in realm: Realm,
        owners: [String],
        filter: NotificationsListViewController.Filter = .all,
        unreadOnly: Bool = false,
        visibleOnly: Bool = true
    ) -> Results<NotificationStorageItem> {
        var results = realm.objects(NotificationStorageItem.self)
            .filter("owner IN %@ AND category_ IN %@", owners, categoryStrings(for: filter))

        if visibleOnly {
            results = results.filter("shouldShow == true")
        }

        if unreadOnly {
            results = results.filter("isRead == false")
        }

        return results.sorted(byKeyPath: "date", ascending: false)
    }

    static func unreadCounters(in realm: Realm, owners: [String]) -> Counters {
        let notifications = notifications(in: realm, owners: owners, unreadOnly: true)
        return Counters(
            total: notifications.count,
            security: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.device.rawValue).count,
            mentions: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.mention.rawValue).count,
            info: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.info.rawValue).count
        )
    }

    static func unreadVisibleCount(in realm: Realm, owners: [String]) -> Int {
        unreadCounters(in: realm, owners: owners).total
    }

    static func rosterMap(in realm: Realm, for items: [NotificationStorageItem]) -> [String: RosterStorageItem] {
        let owners = Array(Set(items.map(\.owner)))
        let jids = Array(Set(items.compactMap { $0.originalSenderJid ?? $0.associatedJid ?? $0.jid }))

        guard owners.isNotEmpty, jids.isNotEmpty else {
            return [:]
        }

        return realm.objects(RosterStorageItem.self)
            .filter("owner IN %@ AND jid IN %@", owners, jids)
            .reduce(into: [String: RosterStorageItem]()) { partialResult, item in
                partialResult[rosterKey(owner: item.owner, jid: item.jid)] = item
            }
    }

    static func displayJid(for item: NotificationStorageItem) -> String {
        item.originalSenderJid ?? item.associatedJid ?? item.jid
    }

    static func displayName(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String {
        let jid = displayJid(for: item)
        if let rosterItem = rosterMap[rosterKey(owner: item.owner, jid: jid)] {
            return rosterItem.displayName
        }
        if let nick = item.displayedNick?.trimmingCharacters(in: .whitespacesAndNewlines), nick.isNotEmpty {
            return nick
        }
        return JidManager.shared.prepareJid(jid: jid)
    }

    static func avatarUrl(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String? {
        let jid = displayJid(for: item)
        return rosterMap[rosterKey(owner: item.owner, jid: jid)]?.avatarUrl
    }

    static func badgeIcon(for category: XMPPNotificationsManager.Category) -> String {
        switch category {
        case .device:
            return "badge-circle-big-security"
        case .mention:
            return "badge-circle-big-mention"
        case .info:
            return "badge-circle-big-info"
        case .contact:
            return "badge-circle-big-bell"
        }
    }

    static func titleText(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String {
        let name = displayName(for: item, rosterMap: rosterMap)
        switch item.category {
        case .device:
            return "New login to server \(name)"
        case .mention:
            return "\(name) mentioned you"
        case .info:
            return "Information from \(name)"
        case .contact:
            return name
        }
    }

    static func messageText(for item: NotificationStorageItem) -> String? {
        switch item.category {
        case .device:
            if let device = item.metadata?["device"] as? String,
               let client = item.metadata?["client"] as? String,
               device.isNotEmpty || client.isNotEmpty {
                return [client, device].filter(\.isNotEmpty).joined(separator: " • ")
            }
            return item.text ?? item.fallbackText
        case .mention:
            return item.text ?? item.fallbackText
        case .info:
            return (item.metadata?["text"] as? String) ?? item.text ?? item.fallbackText
        case .contact:
            return item.text ?? item.fallbackText
        }
    }

    static func sectionTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

}

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
        view.separatorStyle = .singleLine
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 88
        view.cellLayoutMarginsFollowReadableWidth = true
        
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
        self.scheduleDatasourceReload()
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
    private let datasourceQueue = DispatchQueue(label: "com.xabber.notifications.datasource", qos: .userInitiated)
    private var datasourceGeneration: Int = 0
    
    func configureBars() {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: nil)
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
            UIAction(
                title: "Information",
                image: imageLiteral("info.circle"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .info ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.info.rawValue)
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
            let accountActions: [UIMenuElement] = realm
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
                        state: self.filterAccount.value == item.jid ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(account: item.jid)
                        }
                    )
                })

            if accountActions.count > 1 {
                childs.append(
                    UIMenu(
                        title: "Accounts",
                        options: [.displayInline],
                        children: accountActions
                    )
                )
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        
        filterMenu = UIMenu(children: childs)
        
        button.menu = filterMenu
        
        let readAllNotificationsButton = UIBarButtonItem(image: imageLiteral("checkmark"), style: .plain, target: self, action: #selector(onReadAllNotifications))
        if childs.count <= 1 {
            self.navigationItem.setRightBarButtonItems([readAllNotificationsButton], animated: true)
        } else {
            self.navigationItem.setRightBarButtonItems([button, readAllNotificationsButton], animated: true)
        }
    }
        
    @objc
    private func onReadAllNotifications(_ sender: UIBarButtonItem) {
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
            let owners = filterAccount.value.map { [$0] } ?? AccountManager.shared.users.map { $0.jid }
            let allNotifications = NotificationsSupport.notifications(
                in: realm,
                owners: owners,
                filter: self.filter.value
            )
            try realm.write {
                allNotifications.forEach { $0.isRead = true }
            }
            AccountManager.shared.users.forEach { user in
                if user.xmppStream.isAuthenticated {
                    user.action { user, stream in
                        user.notifications.readAll(stream)
                    }
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        scheduleDatasourceReload()
    }

    private func headerSection(for filter: Filter) -> Datasource? {
        switch filter {
        case .all:
            return nil
        case .security:
            return Datasource(title: "", key: "", childs: [
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
        case .mentions:
            return Datasource(title: "", key: "", childs: [
                DatasourceChild(
                    primary: "mention_item_header",
                    category: .mention,
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
        case .info:
            return Datasource(title: "", key: "", childs: [
                DatasourceChild(
                    primary: "info_item_header",
                    category: .info,
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
        }
    }

    private func notificationItemToDatasourceChild(_ item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> DatasourceChild? {
        guard item.category != .contact else {
            return nil
        }

        let title = NSAttributedString(
            string: NotificationsSupport.titleText(for: item, rosterMap: rosterMap),
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        let message = NotificationsSupport.messageText(for: item).map {
            NSAttributedString(
                string: $0,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
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
            avatarUrl: NotificationsSupport.avatarUrl(for: item, rosterMap: rosterMap),
            badgeIcon: NotificationsSupport.badgeIcon(for: item.category),
            isRead: item.isRead,
            isHeader: false
        )
    }

    private func mapResultByDate(_ items: [NotificationStorageItem], rosterMap: [String: RosterStorageItem]) -> [Datasource] {
        var currentDate: String? = nil
        var out: [Datasource] = []

        items.forEach { item in
            let newDate = NotificationsSupport.sectionTitle(for: item.date)
            guard let child = notificationItemToDatasourceChild(item, rosterMap: rosterMap) else {
                return
            }

            if newDate != currentDate {
                currentDate = newDate
                out.append(
                    Datasource(
                        title: newDate,
                        key: "notifications",
                        childs: [child]
                    )
                )
            } else {
                out.last?.childs.append(child)
            }
        }

        return out
    }

    func buildDatasourceSnapshot(filter: Filter, filterAccount: String?) -> [Datasource] {
        do {
            let realm = try WRealm.safe()
            let owners = filterAccount.map { [$0] } ?? AccountManager.shared.users.map { $0.jid }
            let notifications = NotificationsSupport.notifications(in: realm, owners: owners, filter: filter).toArray()
            let rosterMap = NotificationsSupport.rosterMap(in: realm, for: notifications)

            var sections: [Datasource] = []
            if let header = headerSection(for: filter) {
                sections.append(header)
            }
            sections.append(contentsOf: mapResultByDate(notifications, rosterMap: rosterMap))
            return sections.filter { !$0.childs.isEmpty }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            return []
        }
    }

    private func scheduleDatasourceReload() {
        datasourceGeneration += 1
        let generation = datasourceGeneration
        let filter = self.filter.value
        let filterAccount = self.filterAccount.value

        datasourceQueue.async {
            let snapshot = self.buildDatasourceSnapshot(filter: filter, filterAccount: filterAccount)
            DispatchQueue.main.async {
                guard generation == self.datasourceGeneration else {
                    return
                }
                self.datasource = snapshot
                self.emptyScreenShowObserver.accept(snapshot.isEmpty)
                self.configureBars()
                self.tableView.reloadData()
            }
        }
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
                .distinctUntilChanged()
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.filterAccount
                .asObservable()
                .distinctUntilChanged { $0 == $1 }
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
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
        if section == 0 && self.filter.value != .all {
            return .leastNormalMagnitude
        }
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
        return UITableView.automaticDimension
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
