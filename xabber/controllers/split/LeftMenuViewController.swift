//
//  LeftMenuViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 22.04.2024.
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

class LeftMenuViewController: UIViewController {
    
    class AccountView: UIView {
        
        internal let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.alignment = .center
            stack.distribution = .fill
            stack.spacing = 8
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 16, right: 18)
            
            return stack
        }()
        
        internal let labelsStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 2
            
            return stack
        }()
        
        internal let avatarView: UIImageView = {
            let view = UIImageView(frame: CGRect(square: 48))
            if let image = UIImage(named: AccountMasksManager.shared.mask48pt), AccountMasksManager.shared.load() != "square" {
                view.mask = UIImageView(image: image)
            } else {
                view.mask = nil
            }
            view.contentMode = .scaleAspectFill
            
            return view
        }()
        
        internal let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.textColor = .label
            
            return label
        }()
        
        internal let subtitleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            
            return label
        }()
        
        internal let statusIndicator: RoundedStatusView = {
            let view = RoundedStatusView()
            
            view.frame = CGRect(
                origin: CGPoint(x: 34, y: 34),
                size: CGSize(square: 12)
            )
            
            return view
        }()
        
        let userImageView: UIView = {
            let view = UIView(frame: CGRect(square: 48))
            
            view.backgroundColor = .clear
            
            return view
        }()
        
        let errorIndicator: UIImageView = {
            let view = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate))
            
            view.tintColor = .systemOrange
//            view.isHidden = true
            
            return view
        }()
        
        internal func activateConstraints() {
            NSLayoutConstraint.activate([
//                errorIndicator.widthAnchor.constraint(equalToConstant: 24),
                errorIndicator.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        
        public func configure() {
            addSubview(stack)
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                stack.fillSuperviewWithOffset(top: 0, bottom: bottomInset + 8, left: 70, right: 8)
            } else {
                stack.fillSuperviewWithOffset(top: 0, bottom: 8, left: 70, right: 8)
            }
//            stack.addArrangedSubview(avatarView)
            stack.addArrangedSubview(labelsStack)
            stack.addArrangedSubview(errorIndicator)
            labelsStack.addArrangedSubview(titleLabel)
            labelsStack.addArrangedSubview(subtitleLabel)
            addSubview(userImageView)
            userImageView.frame = CGRect(x: 20, y: 10, width: 48, height: 48)
            userImageView.addSubview(avatarView)
            userImageView.addSubview(statusIndicator)
            activateConstraints()
        }
        
        var avatarUrl: String? = nil
        
        public func update(nickname: String, jid: String, status: ResourceStatus, avatarUrl: String) {
            titleLabel.text = nickname
            subtitleLabel.text = jid//JidManager.shared.prepareJid(jid: subtitle)
            statusIndicator.border(1)
            statusIndicator.setStatus(status: status, entity: .contact)
            if avatarUrl != self.avatarUrl {
                DefaultAvatarManager.shared.getAvatar(url: avatarUrl, jid: jid, owner: jid, size: 48) { image in
                    if let image = image {
                        self.avatarUrl = avatarUrl
                        self.avatarView.image = image
                    } else {
                        self.avatarView.image = UIImageView.getDefaultAvatar(for: jid, owner: jid, size: 48)
                    }
                }
            }
        }
    }
    
    struct Datasource {
        let title: String
        let icon: String
        let key: String
        let category: String
        var subtitle: String
        var showTriangle: Bool
    }
    
    var datasource: [[Datasource]] = []
    
    var chatsVc: LastChatsViewController? = nil
    var archivedVc: LastChatsViewController? = nil
    var callsVc: LastCallsViewController? = nil
    var notificationsVc: NotificationsListViewController? = nil
    var notificationsCategoriesVc: NotificationsCategoriesViewController? = nil
    var contactsCategoriesVc: ContactsCategoryViewController? = nil
    var groupsCategoriesVc: ContactsCategoryViewController? = nil
    var contactsVc: ContactsViewController? = nil
    var groupsVc: ContactsViewController? = nil
    var savedMessagesChatsVc: LastChatsViewController? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .grouped)
        
        view.register(MenuItemTableCell.self, forCellReuseIdentifier: MenuItemTableCell.cellName)
//        view.register(UITableViewCell.self, forCellReuseIdentifier: "tablecell")
        view.separatorStyle = .none
        view.isScrollEnabled = false
        
        return view
    }()
    
    internal let accountButton: UIButton = {
        let button = UIButton(frame: .zero)
        
        return button
    }()
    
    internal let accountView: AccountView = {
        let view = AccountView()
        
        return view
    }()
    
    var previousSelectedKey: String? = "chat"
    
    private func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true").sorted(byKeyPath: "order")
            let jids = accounts.toArray().compactMap({ return $0.jid })
            var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
            ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
            if CommonConfigManager.shared.config.support_jid.isNotEmpty {
                ignoredJids.append(CommonConfigManager.shared.config.support_jid)
            }
            var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
            ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
            ignoredJids.append(contentsOf: Array(ignoredAbuse))
            let chats = realm.objects(LastChatsStorageItem.self).filter("isArchived == false AND unread > 0").compactMap({ $0.unread }).reduce(0, +)
            let archived = realm.objects(LastChatsStorageItem.self).filter("isArchived == true AND unread > 0").compactMap({ $0.unread }).reduce(0, +)
            let calls = realm.objects(CallMetadataStorageItem.self)
            let contacts = realm.objects(RosterStorageItem.self).filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
            let notifications = realm.objects(NotificationStorageItem.self).filter("isRead == false AND shouldShow == true")
            let invitations = realm.objects(GroupchatInvitesStorageItem.self).filter("owner IN %@ AND isRead == false", jids)
            if CommonConfigManager.shared.config.support_groupchats {
                self.datasource = [[
                    Datasource(title: "Chats", icon: "custom.bubble", key: "chat", category: "", subtitle: "\(chats)", showTriangle: false),
                    Datasource(title: "Calls", icon: "phone", key: "calls", category: "", subtitle: "\(calls.count)", showTriangle: false),
                    Datasource(title: "Notifications", icon: "bell", key: "notifications", category: "", subtitle: "\(notifications.count)", showTriangle: false),
                    Datasource(title: "Contacts", icon: "person", key: "contacts", category: "contacts", subtitle: "\(contacts.count)", showTriangle: false),
                    Datasource(title: "Groups", icon: "person.2", key: "groups", category: "public", subtitle: "\(invitations.count)", showTriangle: false),
                    Datasource(title: "Archive", icon: "archivebox", key: "archive", category: "", subtitle: "\(archived)", showTriangle: false),
                    Datasource(title: "Saved messages", icon: "bookmark", key: "saved", category: "", subtitle: "0", showTriangle: false),
                ],[
                   Datasource(title: "Settings", icon: "gearshape", key: "settings", category: "", subtitle: "0", showTriangle: false),
                ]
               ]
            } else {
                self.datasource = [[
                    Datasource(title: "Chats", icon: "custom.bubble", key: "chat", category: "", subtitle: "\(chats)", showTriangle: false),
                    Datasource(title: "Calls", icon: "phone", key: "calls", category: "", subtitle: "\(calls.count)", showTriangle: false),
                    Datasource(title: "Notifications", icon: "bell", key: "notifications", category: "", subtitle: "\(notifications.count)", showTriangle: false),
                    Datasource(title: "Contacts", icon: "person", key: "contacts", category: "contacts", subtitle: "\(contacts.count)", showTriangle: false),
                    Datasource(title: "Archive", icon: "archivebox", key: "archive", category: "", subtitle: "\(archived)", showTriangle: false),
                    Datasource(title: "Saved messages", icon: "bookmark", key: "saved", category: "", subtitle: "0", showTriangle: false),
                ],[
                   Datasource(title: "Settings", icon: "gearshape", key: "settings", category: "", subtitle: "0", showTriangle: false),
                ]
               ]
            }
            
        } catch {
            DDLogDebug("LeftMenuViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    @objc
    private func onAppear() {
        
    }
    
    var bag = DisposeBag()
    
    enum TriangleIndicatorStyle {
        case none
        case orangeTriangle
        case redTriangle
    }
    
    var triangleIndicatorStyle: TriangleIndicatorStyle = .none
    
    func subscribe() {
        self.bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            let accounts = realm.objects(AccountStorageItem.self).filter("enabled == true").sorted(byKeyPath: "order")
            let jids = accounts.toArray().compactMap({ return $0.jid })
            var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
            ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
            if CommonConfigManager.shared.config.support_jid.isNotEmpty {
                ignoredJids.append(CommonConfigManager.shared.config.support_jid)
            }
            var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
            ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
            ignoredJids.append(contentsOf: Array(ignoredAbuse))
            let chats = realm.objects(LastChatsStorageItem.self).filter("isArchived == false AND unread > 0")
            let archived = realm.objects(LastChatsStorageItem.self).filter("isArchived == true AND unread > 0")
            let calls = realm.objects(CallMetadataStorageItem.self)
            let contacts = realm.objects(RosterStorageItem.self).filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
            let notifications = realm.objects(NotificationStorageItem.self).filter("isRead == false AND shouldShow == true")
            let invitations = realm.objects(GroupchatInvitesStorageItem.self).filter("owner IN %@ AND isRead == false", jids)
            let section = 0
            
            let badDevices = realm
                .objects(SignalDeviceStorageItem.self)
                .filter("owner IN %@ AND owner == jid AND state_ IN %@", jids, [SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.fingerprintChanged.rawValue, SignalDeviceStorageItem.TrustState.revoked.rawValue])
            
            Observable
                .collection(from: badDevices)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if results.isEmpty {
                        self.accountView.errorIndicator.isHidden = true
                        self.triangleIndicatorStyle = .none
                        return
                    }
                    self.accountView.errorIndicator.isHidden = false
                    if results.filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).count > 0 {
                        self.accountView.errorIndicator.tintColor = .systemRed
                        self.triangleIndicatorStyle = .redTriangle
                        return
                    }
                    self.accountView.errorIndicator.tintColor = .systemOrange
                    self.triangleIndicatorStyle = .orangeTriangle
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: bag)

            
            Observable
                .collection(from: accounts)
                .subscribe { results in
                    if let item = results.first {
                        self.accountView.update(nickname: item.username, jid: item.jid, status: .online, avatarUrl: item.avatarMaxUrl ?? item.avatarMinUrl ?? item.oldschoolAvatarKey ?? "none")
                    }
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)

            
            Observable
                .collection(from: chats)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "chat" }) {
                        self.datasource[section][index].subtitle = "\(results.compactMap({ $0.unread }).reduce(0, +))"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: archived)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "archive" }) {
                        self.datasource[section][index].subtitle = "\(results.compactMap({ $0.unread }).reduce(0, +))"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: calls)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "calls" }) {
                        self.datasource[section][index].subtitle = "\(results.count)"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: contacts)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "contacts" }) {
                        self.datasource[section][index].subtitle = "\(results.count)"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: invitations)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "groups" }) {
                        self.datasource[section][index].subtitle = "\(results.count)"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: notifications)
                .skip(1)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if let index = self.datasource[section].firstIndex(where: { $0.key == "notifications" }) {
                        self.datasource[section][index].subtitle = "\(results.count)"
                        self.tableView.reloadRows(at: [IndexPath(row: index, section: section)], with: .none)
                    }
                    
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }
                .disposed(by: self.bag)
            
        } catch {
            DDLogDebug("LeftMenuViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func unsubscribe() {
        self.bag = DisposeBag()
    }
    
//    internal let bottomBar: AccountView = {
//        let view = AccountView()
//        
//        return view
//    }()
    
    public func configure() {
        self.title = CommonConfigManager.shared.config.app_name.capitalized
        
        navigationItem.largeTitleDisplayMode = .automatic
        navigationController?.navigationBar.prefersLargeTitles = true
        self.navigationItem.backButtonDisplayMode = .minimal
//        if CommonConfigManager.shared.config.use_large_title {
//            navigationItem.largeTitleDisplayMode = .automatic
//        } else {
//            navigationItem.largeTitleDisplayMode = .never
//        }
//        navigationController?.navigationBar.prefersLargeTitles = CommonConfigManager.shared.config.use_large_title
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(onTableViewEmptySpaceTap))
        tapGesture.cancelsTouchesInView = false
//        tableView.addGestureRecognizer(tapGesture)
        
    }
    
    @objc
    func onTableViewEmptySpaceTap(_ sender: AnyObject) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.hide(.primary)
        } else {
            self.splitViewController?.show(.supplementary)
            self.splitViewController?.hide(.primary)
        }
    }
 
    @objc
    func onAccountButton(_ sender: UIButton) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc, parent: self)
        self.splitViewController?.show(.supplementary)
        self.splitViewController?.hide(.primary)
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


extension LeftMenuViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemTableCell.cellName, for: indexPath) as? MenuItemTableCell else {
            fatalError()
        }
        let item = datasource[indexPath.section][indexPath.row]
        
        cell.configure(title: item.title, badge: item.subtitle, icon: item.icon, isImportant: true)
        if item.key == "archive" {
            cell.badgeView.configuration?.baseBackgroundColor = .systemGray
        } else {
            cell.badgeView.configuration?.baseBackgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
        }
        cell.selectionStyle = .none
        return cell
    }
    
    
}

class MenuItemHeaderTableCell: UITableViewCell {
    static let cellName: String = "MenuItemHeaderTableCell"
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 0
        stack.layoutMargins = UIEdgeInsets(top: 12, bottom: 12, left: 24, right: 24)
        stack.isLayoutMarginsRelativeArrangement = true
        
//        stack.layer.cornerRadius = 8
//        stack.layer.masksToBounds = true
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 25, weight: .bold)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        
        return label
    }()
    
    let subtitleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        
        return label
    }()
    
    let iconView: UIButton = {
        let button = UIButton()
        
        return button
    }()
    
    func configure(title: String, subtitle: String, icon: String, color: UIColor, withCircle: Bool = false) {
        self.titleLabel.text = title
        self.subtitleLabel.text = subtitle
        
        var configuration = UIButton.Configuration.filled()
        if withCircle {
            configuration.baseBackgroundColor = .secondarySystemBackground
        } else {
            configuration.baseBackgroundColor = .systemBackground
        }
        
        configuration.baseForegroundColor = color
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        if withCircle {
            configuration.image = imageLiteral(icon)?.upscale(dimension: 48).withRenderingMode(.alwaysTemplate)
            self.stack.setCustomSpacing(8, after: self.iconView)
        } else {
            configuration.image = imageLiteral(icon)?.upscale(dimension: 76).withRenderingMode(.alwaysTemplate)
            self.stack.setCustomSpacing(0, after: self.iconView)
        }
        self.stack.setCustomSpacing(4, after: self.titleLabel)
        self.iconView.configuration = configuration
    }
    
    func setupSubviews() {
        self.backgroundColor = .systemBackground
        self.contentView.addSubview(stack)
        self.stack.fillSuperviewWithOffset(top: 0, bottom: 16, left: 16, right: 16)
        self.stack.addArrangedSubview(self.iconView)
        self.stack.addArrangedSubview(self.titleLabel)
        self.stack.addArrangedSubview(self.subtitleLabel)
//        self.stack.backgroundColor = .systemBackground
//        self.stack.setCustomSpacing(8, after: self.titleLabel)
        self.activateConstraints()
    }
    
    func activateConstraints() {
        NSLayoutConstraint.activate([
            self.iconView.widthAnchor.constraint(equalToConstant: 96),
            self.iconView.heightAnchor.constraint(equalToConstant: 96)
        ])
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }
}

class MenuItemTableCell: UITableViewCell {
    static let cellName: String = "MenuItemTableCell"
    
    let stack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        stack.layoutMargins = UIEdgeInsets(top: 2, bottom: 0, left: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        
        return stack
    }()
    
    let titleLabel: UILabel = {
        let label = UILabel()
        
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        return label
    }()
    
    let badgeView: UIButton = {
        let view = UIButton()

        return view
    }()
    
    func configure(title: String, badge: String, icon: String, isImportant: Bool) {
        self.titleLabel.text = title
        self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate)
        self.badgeView.setTitle("\(badge)", for: .normal)
        self.badgeView.isHidden = badge == "0" ? true : false
        if isImportant {
            var configuration = UIButton.Configuration.filled()
            configuration.baseBackgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
            configuration.baseForegroundColor = .white
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            self.badgeView.configuration = configuration
        } else {
            var configuration = UIButton.Configuration.filled()
            configuration.baseBackgroundColor = .clear
            configuration.baseForegroundColor = .secondaryLabel
            configuration.buttonSize = .mini
            configuration.cornerStyle = .capsule
            self.badgeView.configuration = configuration
        }
        self.badgeView.updateConfiguration()
        self.badgeView.setNeedsLayout()
        self.badgeView.layoutIfNeeded()
    }
    
    func setupSubviews() {
        self.backgroundColor = .clear
        self.layer.cornerRadius = 8
        self.layer.masksToBounds = true
        self.contentView.addSubview(stack)
        self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 56, right: 4)
        self.stack.addArrangedSubview(self.titleLabel)
        self.stack.addArrangedSubview(self.badgeView)
    }
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupSubviews()
    }
    
}

extension LeftMenuViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }
    
    private func show(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) {
        if #available(iOS 26, *) {
            // Code for iOS 26 and above
            self.showNew(controller: vc, kind: kind, isNotifications: isNotifications, isContacts: isContacts, isGroups: isGroups, category: category, leftMenuDelegate: leftMenuDelegate)
        } else {
            // Fallback for older iOS versions
            self.showOld(controller: vc, kind: kind, isNotifications: isNotifications, isContacts: isContacts, isGroups: isGroups, category: category, leftMenuDelegate: leftMenuDelegate)
        }
    }
    
    private func showNew(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) {
        let svc: UIViewController
        vc.resetState()
        if isNotifications {
            svc = NotificationsListViewController()
            (vc as? NotificationsCategoriesViewController)?.filterDelegate = (svc as? NotificationsListViewController)
        } else if isContacts {
            svc = ContactsViewController()
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
        } else if isGroups {
            svc = ContactsViewController()
            (svc as? ContactsViewController)?.isGroup = true
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
        } else {
            svc = EmptyChatViewController()
        }
        (svc as? EmptyChatViewController)?.kind = kind
        
//        let nsvc = UINavigationController(rootViewController: svc)
        guard let splitVC = self.splitViewController else {
            print("Error: splitViewController is nil")
            return
        }
        
        splitVC.setViewController(UINavigationController(rootViewController: vc), for: .supplementary)
        splitVC.setViewController(svc, for: .secondary)
        splitVC.show(.supplementary)
        splitVC.hide(.primary)
    }
    
    private func showOld(controller vc: BaseViewController, kind: EmptyChatViewController.Kind, isNotifications: Bool = false, isContacts: Bool = false, isGroups: Bool = false, category: String? = nil, leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil) {
        let svc: UIViewController
        vc.resetState()
        if isNotifications {
            svc = NotificationsListViewController()
            (vc as? NotificationsCategoriesViewController)?.filterDelegate = (svc as? NotificationsListViewController)
        } else if isContacts {
            svc = ContactsViewController()
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
            
        } else if isGroups {
            svc = ContactsViewController()
            (svc as? ContactsViewController)?.isGroup = true
            (vc as? ContactsCategoryViewController)?.filterDelegate = (svc as? ContactsViewController)
            (svc as? ContactsViewController)?.categoryDelegate = (vc as? ContactsCategoryViewController)
            (svc as? ContactsViewController)?.leftMenuDelegate = leftMenuDelegate
            (svc as? ContactsViewController)?.didSelectSpecialCategory(category ?? "")
            
        } else {
            svc = EmptyChatViewController()
        }
        (svc as? EmptyChatViewController)?.kind = kind
        let nsvc = UINavigationController(rootViewController: svc)
        self.splitViewController?.viewControllers = [self, vc, nsvc]
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.hide(.primary)
        } else {
            self.splitViewController!.show(.supplementary)
        }
    }
    
    private func showSavedMessages(controller vc: UIViewController) {
        self.splitViewController?.viewControllers = [self, vc]
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.hide(.primary)
        } else {
            self.splitViewController?.show(.supplementary)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = self.datasource[indexPath.section][indexPath.row].key
        if key == "settings" {
            let vc = SettingsViewController()
            vc.jid = AccountManager.shared.users.first?.jid ?? ""
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            showModal(vc, parent: self)
            self.splitViewController?.show(.supplementary)
            self.splitViewController?.hide(.primary)
        } else {
            let category = self.datasource[indexPath.section][indexPath.row].category
            self.didSelectRootScreenBy(key: key)
        }
    }
}

extension LeftMenuViewController: LeftMenuSelectRootScreenDelegate {
    
    func didSelectRootScreenBy(key: String, category: String? = nil) {
        if self.previousSelectedKey == key {
            if UIDevice.current.userInterfaceIdiom == .pad {
                self.splitViewController?.hide(.primary)
            } else {
                self.splitViewController?.show(.supplementary)
            }
            return
        }
        self.previousSelectedKey = key
        switch key {
            case "chat":
                if let vc = self.chatsVc {
                    vc.filter.accept(.chats)
                    self.show(controller: vc, kind: .emptyChat)
                    vc.leftMenuSelectRootCategoryDelegate = self
                  
                } else {
                    let vc = LastChatsViewController()
                    self.chatsVc = vc
                    self.show(controller: vc, kind: .emptyChat)
                    vc.leftMenuSelectRootCategoryDelegate = self
                    
                }
            case "calls":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.callsVc {
                    vc.leftMenuDelegate = self
                    self.show(controller: vc, kind: .emptyCall)
//                    self.showEmptyDetail(for: .emptyCall)
                } else {
                    let vc = LastCallsViewController()
                    vc.leftMenuDelegate = self
                    self.callsVc = vc
                    self.show(controller: vc, kind: .emptyCall)
//                    self.showEmptyDetail(for: .emptyCall)
                }
            case "mentions":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.notificationsVc {
                    self.show(controller: vc, kind: .emptyChat)
                } else {
                    let vc = NotificationsListViewController()
                    self.notificationsVc = vc
                    self.show(controller: vc, kind: .emptyChat)
                }
            case "notifications":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if let vc = self.notificationsCategoriesVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, isNotifications: true)
                    } else {
                        let vc = NotificationsCategoriesViewController()
                        vc.leftMenuDelegate = self
                        self.notificationsCategoriesVc = vc
                        self.show(controller: vc, kind: .emptyChat, isNotifications: true)
                    }
                } else {
                    if let vc = self.notificationsVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat)
                    } else {
                        let vc = NotificationsListViewController()
                        vc.leftMenuDelegate = self
                        self.notificationsVc = vc
                        self.show(controller: vc, kind: .emptyChat)
                    }
                }
                
            case "contacts":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if let vc = self.contactsCategoriesVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, isContacts: true, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsCategoryViewController()
                        self.contactsCategoriesVc = vc
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, isContacts: true, category: category, leftMenuDelegate: self)
                    }
                } else {
                    if let vc = self.contactsVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsViewController()
                        vc.leftMenuDelegate = self
                        self.contactsVc = vc
                        self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    }
                }
            case "groups":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if let vc = self.groupsCategoriesVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, isGroups: true, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsCategoryViewController()
                        vc.isGroup = true
                        vc.leftMenuDelegate = self
                        self.groupsCategoriesVc = vc
                        self.show(controller: vc, kind: .emptyChat, isGroups: true, category: category, leftMenuDelegate: self)
                    }
                } else {
                    if let vc = self.groupsVc {
                        vc.leftMenuDelegate = self
                        self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    } else {
                        let vc = ContactsViewController()
                        vc.isGroup = true
                        vc.leftMenuDelegate = self
                        self.groupsVc = vc
                        self.show(controller: vc, kind: .emptyChat, category: category, leftMenuDelegate: self)
                    }
                }
            case "archive":
                if let vc = self.archivedVc {
                    vc.filter.accept(.archived)
                    vc.leftMenuSelectRootCategoryDelegate = self
                    self.show(controller: vc, kind: .emptyChat)
                } else {
                    let vc = LastChatsViewController()
                    vc.shouldShowBottomBar = false
                    vc.leftMenuSelectRootCategoryDelegate = self
                    vc.filter.accept(.archived)
                    self.archivedVc = vc
                    self.show(controller: vc, kind: .emptyChat)
//                    self.showEmptyDetail(for: .emptyChat)
                }
            case "saved":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.savedMessagesChatsVc {
                    vc.leftMenuSelectRootCategoryDelegate = self
                    self.showSavedMessages(controller: vc)
                } else {
                    let vc = LastChatsViewController()
                    vc.shouldShowBottomBar = false
                    vc.leftMenuSelectRootCategoryDelegate = self
                    vc.filter.accept(.saved)
                    self.savedMessagesChatsVc = vc
                    self.showSavedMessages(controller: vc)
                }
            default:
                break
        }
    }
    
    func selectRootScreenAndCategory(screen key: String, category: String?) {
        self.didSelectRootScreenBy(key: key, category: category)
    }
    
    func openChatlistWithChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, configure: ((ChatViewController?) -> Void)?) {
        self.previousSelectedKey = nil
        if let vc = self.chatsVc {
            vc.filter.accept(.chats)
            self.show(controller: vc, kind: .emptyChat)
            vc.leftMenuSelectRootCategoryDelegate = self
            vc.stackNewChat(owner: owner, jid: jid, conversationType: conversationType, configure: configure)
//                    self.showEmptyDetail(for: .emptyChat)
        } else {
            let vc = LastChatsViewController()
            self.chatsVc = vc
            self.show(controller: vc, kind: .emptyChat)
            vc.leftMenuSelectRootCategoryDelegate = self
            vc.stackNewChat(owner: owner, jid: jid, conversationType: conversationType, configure: configure)
//                    self.showEmptyDetail(for: .emptyChat)
        }
    }
}

protocol LeftMenuSelectRootScreenDelegate {
    func selectRootScreenAndCategory(screen key: String, category: String?)
    func openChatlistWithChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, configure: ((ChatViewController?) -> Void)?)
}
