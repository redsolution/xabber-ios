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
        let view = UITableView(frame: .zero, style: .plain)
        
        view.backgroundColor = .systemBackground
        
        view.register(NotificationItemCell.self, forCellReuseIdentifier: NotificationItemCell.cellName)
        view.register(NotificationsSubscribtionsListViewController.ContactItemCell.self, forCellReuseIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName)
        
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
    
    struct DatasourceChild {
        let category: XMPPNotificationsManager.Category
        let owner: String
        let jid: String
        let title: NSAttributedString
        let message: NSAttributedString?
        let key: String?
        let date: Date
        let avatarUrl: String?
        let badgeIcon: String
    }
    
    var datasource: [Datasource] = []
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperviewWithOffset(top: -20, bottom: 0, left: 0, right: 0)
        
        self.emptyView.isHidden = !self.emptyScreenShowObserver.value
        self.view.addSubview(self.emptyView)
        self.emptyView.fillSuperview()
        self.view.bringSubviewToFront(self.emptyView)
    }
    
    override func configure() {
        super.configure()
        if CommonConfigManager.shared.interfaceType == .split {
            self.title = "All"
        }
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.emptyView.configure {
            
        }
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
            UIAction(
                title: "Info",
                image: imageLiteral("info"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .info ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.info.rawValue)
                }),
            UIMenu(title: "Accounts", subtitle: "sdaff", image: nil, identifier: nil, options: .displayInline, children: [])
        ]
        
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
            
            childs.append(contentsOf: accounts)
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        
        filterMenu = UIMenu(options: [.singleSelection], children: childs)
        
        button.menu = filterMenu
        
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                self.navigationItem.setRightBarButton(button, animated: true)
            case .split:
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setRightBarButton(button, animated: true)
                }
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
            let contactNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter(
                    "shouldShow == true AND owner IN %@ AND category_ == %@",
                    jids,
                    XMPPNotificationsManager.Category.contact.rawValue
                )
            
            if self.filter.value == .all {
                
                self.datasource = [
                    mapResult(contactNotifications, title: "Subscription requests", key: "subscribtion_requests")
                ]
            } else {
                self.datasource = []
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
                do {
                    let realm = try WRealm.safe()
                    var usernameRaw = item.jid
                    var avatarUrl: String? = nil
                    if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: item.jid, owner: item.owner)) {
                        usernameRaw = instance.displayName
                        avatarUrl = instance.avatarUrl
                    }
                    var message: NSAttributedString? = nil
                    if let text = item.metadata?["message"] as? String {
                        message = NSAttributedString(string: text, attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .body),
                            .foregroundColor: AccountColorManager.shared.palette(for: item.owner).tint700
                        ])
                    }
                    let username: NSAttributedString = NSAttributedString(string: usernameRaw, attributes: [
                        .font: UIFont.boldSystemFont(ofSize: 17),
                        .foregroundColor: UIColor.label
                    ])
                    return DatasourceChild(
                        category: item.category,
                        owner: item.owner,
                        jid: item.jid,
                        title: username,
                        message: message,
                        key: item.uniqueId,
                        date: item.date,
                        avatarUrl: avatarUrl,
                        badgeIcon: "plus.circle.fill"
                    )
                } catch {
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                    return nil
                }
                
            case .device:
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: "New login", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: " to server ", attributes: [
                    .font: UIFont.systemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: item.associatedJid ?? item.jid, attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                
                return DatasourceChild(
                    category: item.category,
                    owner: item.owner,
                    jid: item.jid,
                    title: title,
                    message: nil,
                    key: item.jid,
                    date: item.date,
                    avatarUrl: nil,
                    badgeIcon: "xabber.shield.circle.fill"
                )
            case .mention:
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: "Juliet", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: " mentioned you in ", attributes: [
                    .font: UIFont.systemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: "mychat@capulet.it: ", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: "... the clock strook nine when I did send the nurse...", attributes: [
                    .font: UIFont.italicSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.secondaryLabel
                ]))
                return DatasourceChild(
                    category: item.category,
                    owner: item.owner,
                    jid: item.jid,
                    title: title,
                    message: nil,
                    key: item.jid,
                    date: item.date,
                    avatarUrl: nil,
                    badgeIcon: "at.circle.fill"
                )
                
            case .info:
                let title = NSMutableAttributedString()
                title.append(NSAttributedString(string: "New information message", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: " from server ", attributes: [
                    .font: UIFont.systemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                title.append(NSAttributedString(string: "\(item.associatedJid ?? item.jid): ", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: UIColor.label
                ]))
                if let message = item.metadata?["text"] as? String {
                    title.append(NSAttributedString(string: message, attributes: [
                        .font: UIFont.italicSystemFont(ofSize: 17),
                        .foregroundColor: UIColor.secondaryLabel
                    ]))
                }
                return DatasourceChild(
                    category: item.category,
                    owner: item.owner,
                    jid: item.jid,
                    title: title,
                    message: nil,
                    key: item.jid,
                    date: item.date,
                    avatarUrl: nil,
                    badgeIcon: "info.circle.fill"
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
                    var title = dateFormatter.string(from: item.date)//string(from: item.date)
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
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.configureBars()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
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
    
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        var configuration = UIListContentConfiguration.sidebarHeader()
//        configuration.textProperties.
        configuration.text = self.datasource[section].title
        
//        configuration.textProperties.font = UIFont.preferredFont(forTextStyle: .title2)
//        configuration.textProperties.color = .label
//        configuration.textProperties.transform = .capitalized
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 6, bottom: 0, trailing: 6)
        
        (view as? UITableViewHeaderFooterView)?.contentConfiguration = configuration
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 60
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
        switch section.key {
            case "subscribtion_requests":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName, for: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell else {
                    fatalError()
                }
                
                cell.configure(
                    owner: item.owner,
                    username: item.title,
                    jid: item.jid,
                    message: item.message,
                    icon: item.badgeIcon,
                    avatarUrl: item.avatarUrl,
                    uuid: item.key ?? ""
                )
                
                cell.addButtonAction = self.addButtonAction
                cell.declineButtonAction = self.declineButtonAction
                
                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
                cell.selectedBackgroundView = view
                
                cell.accessoryType = .detailButton
                
                return cell
            case "notifications":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationItemCell.cellName, for: indexPath) as? NotificationItemCell else {
                    fatalError()
                }
                
                cell.configure(
                    jid: item.jid,
                    owner: item.owner,
                    avatarUrl: item.avatarUrl,
                    icon: item.badgeIcon,
                    title: item.title,
                    date: item.date
                )
                
                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
                cell.selectedBackgroundView = view
                
                cell.accessoryType = .disclosureIndicator
                
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
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let section = self.datasource[indexPath.section]
        let item = section.childs[indexPath.row]
        switch section.key {
            case "subscribtion_requests":
                let vc = ContactInfoViewController()
                vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                vc.owner = item.owner
                vc.jid = item.jid
                showModal(vc, parent: self)
            case "notifications":
                switch item.category {
                    case .device:
                        let vc = DevicesListViewController()
                        vc.configure(for: item.owner)
                        showModal(vc, parent: self)
                    default:
                        break
                }
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
        if let category = category {
            let filterValue = Filter(rawValue: category) ?? .all
            self.filter.accept(self.filter.value == filterValue ? .all : filterValue)
        } else {
            self.filter.accept(.all)
        }
    }
}
