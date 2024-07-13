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
        var subtitle: String
    }
    
    var datasource: [[Datasource]] = []
    
    var chatsVc: LastChatsViewController? = nil
    var archivedVc: LastChatsViewController? = nil
    var callsVc: LastCallsViewController? = nil
    var notificationsVc: NotificationsListViewController? = nil
    var notificationsCategoriesVc: NotificationsCategoriesViewController? = nil
    var contactsVc: ContactsViewController? = nil
    
    private let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
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
            let chatsCount = realm.objects(LastChatsStorageItem.self).count
            let archivedCount = realm.objects(LastChatsStorageItem.self).filter("isArchived == true").count
            let callsCount = realm.objects(CallMetadataStorageItem.self).count
            let contactsCount = realm.objects(RosterStorageItem.self).filter("isHidden == false AND removed == false").count
            let notificationsCount = realm.objects(NotificationStorageItem.self).count
            self.datasource = [[
                Datasource(title: "Chats", icon: "message", key: "chat", subtitle: "\(chatsCount)"),
                Datasource(title: "Calls", icon: "phone", key: "calls", subtitle: "\(callsCount)"),
    //            Datasource(title: "Mentions", icon: "at", key: "mentions"),
                Datasource(title: "Notifications", icon: "bell.badge", key: "notifications", subtitle: "\(notificationsCount)"),
                Datasource(title: "Contacts", icon: "person.2", key: "contacts", subtitle: "\(contactsCount)"),
                Datasource(title: "Archive", icon: "archivebox", key: "archive", subtitle: "\(archivedCount)"),
    //            Datasource(title: "Saved messages", icon: "bookmark", key: "saved"),
            ],
           ]
        } catch {
            DDLogDebug("LeftMenuViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    @objc
    private func onAppear() {
        
    }
    
    var bag = DisposeBag()
    
    func subscribe() {
        self.bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            let chats = realm.objects(LastChatsStorageItem.self)
            let archived = realm.objects(LastChatsStorageItem.self).filter("isArchived == true")
            let calls = realm.objects(CallMetadataStorageItem.self)
            let contacts = realm.objects(RosterStorageItem.self).filter("isHidden == false AND removed == false")
            let notifications = realm.objects(NotificationStorageItem.self)
            
            let section = 0
            
            let accounts = realm.objects(AccountStorageItem.self).sorted(byKeyPath: "order")
            let enabledAccounts = accounts.toArray().compactMap({ return $0.enabled ? $0.jid : nil })
            
            let badDevices = realm
                .objects(SignalDeviceStorageItem.self)
                .filter("owner IN %@ AND owner == jid AND state_ IN %@", enabledAccounts, [SignalDeviceStorageItem.TrustState.unknown.rawValue, SignalDeviceStorageItem.TrustState.fingerprintChanged.rawValue, SignalDeviceStorageItem.TrustState.revoked.rawValue])
            
            Observable
                .collection(from: badDevices)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    if results.isEmpty {
                        self.accountView.errorIndicator.isHidden = true
                        return
                    }
                    self.accountView.errorIndicator.isHidden = false
                    if results.filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).count > 0 {
                        self.accountView.errorIndicator.tintColor = .systemRed
                        return
                    }
                    self.accountView.errorIndicator.tintColor = .systemOrange
                    
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
                        self.datasource[section][index].subtitle = "\(results.count)"
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
                        self.datasource[section][index].subtitle = "\(results.count)"
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
        navigationController?.navigationBar.prefersLargeTitles = true
        
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        loadDatasource()
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(onTableViewEmptySpaceTap))
        tapGesture.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tapGesture)
        
    }
    
    @objc
    func onTableViewEmptySpaceTap(_ sender: AnyObject) {
        self.splitViewController?.hide(.primary)
    }
    
    func setupBottomBar() {
        var inputHeight: CGFloat = 80
        var leftInset: CGFloat = 0
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            leftInset += 100
        }
        let size = CGSize(width: self.view.bounds.width - leftInset, height: inputHeight)
        let frame = CGRect(origin: CGPoint(x: leftInset, y: self.view.bounds.height - inputHeight), size: size)
//        bottomBar.frame = frame
        self.accountView.frame = CGRect(origin: .zero, size: size)
        self.accountView.configure()
        self.accountButton.frame = frame
        self.accountButton.addSubview(accountView)
        self.view.addSubview(accountButton)
        self.view.bringSubviewToFront(accountButton)
        self.accountButton.addTarget(self, action: #selector(onAccountButton), for: .touchUpInside)
        self.accountView.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            self.accountButton.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.accountButton.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.accountButton.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.accountButton.heightAnchor.constraint(equalToConstant: 80),
        ])
    }
    
    @objc
    func onAccountButton(_ sender: UIButton) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc)
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
        setupBottomBar()
        
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
        
        cell.configure(title: item.title, badge: item.subtitle, icon: item.icon)

        return cell
    }
    
    
}

extension LeftMenuViewController {
    class MenuItemTableCell: UITableViewCell {
        static let cellName: String = "MenuItemTableCell"
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .horizontal
            stack.distribution = .fill
            stack.alignment = .center
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
                        
            return label
        }()
        
        let badgeView: UIButton = {
            let view = UIButton()
            
//            view.contentEdgeInsets = UIEdgeInsets(square: 4)
//            view.backgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
//            view.setTitleColor(.white, for: .normal)
            view.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            view.layer.masksToBounds = true
            view.layer.cornerRadius = 10
            
            var configuration = UIButton.Configuration.filled()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            configuration.baseBackgroundColor = UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)
            configuration.baseForegroundColor = .white
            configuration.buttonSize = .small
            
            view.configuration = configuration
            
            return view
        }()
        
        func configure(title: String, badge: String, icon: String) {
            self.titleLabel.text = title
            self.imageView?.image = (UIImage(named: icon) ?? UIImage(systemName: icon))?.withRenderingMode(.alwaysTemplate)
            self.selectionStyle = .none
            self.badgeView.setTitle("\(badge)", for: .normal)
            self.badgeView.isHidden = badge == "0" ? true : false
        }
        
        func setupSubviews() {
            self.backgroundColor = .clear
            self.layer.cornerRadius = 8
            self.layer.masksToBounds = true
            self.selectionStyle = .none
            self.contentView.addSubview(stack)
            self.stack.fillSuperviewWithOffset(top: 0, bottom: 4, left: 56, right: 0)
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
}

extension LeftMenuViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44
    }
    
    private func show(controller vc: UIViewController) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.splitViewController?.setViewController(vc, for: .supplementary)
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
        let key = self.datasource[indexPath.section][indexPath.row].key
        if self.previousSelectedKey == key {
            self.splitViewController?.hide(.primary)
            return
        }
        self.previousSelectedKey = key
        self.onAppear()
        switch key {
            case "chat":
                if let vc = self.chatsVc {
                    vc.filter.accept(.chats)
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyChat
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                } else {
                    let vc = LastChatsViewController()
                    self.chatsVc = vc
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyChat
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                }
            case "calls":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.callsVc {
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyCall
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                } else {
                    let vc = LastCallsViewController()
                    self.callsVc = vc
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyCall
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                }
            case "mentions":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.notificationsVc {
                    self.show(controller: vc)
                } else {
                    let vc = NotificationsListViewController()
                    self.notificationsVc = vc
                    self.show(controller: vc)
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
                        self.show(controller: vc)
                        let svc = NotificationsListViewController()
                        self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                        
                    } else {
                        let vc = NotificationsCategoriesViewController()
                        self.notificationsCategoriesVc = vc
                        self.show(controller: vc)
                        let svc = NotificationsListViewController()
                        
                        self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                    }
                } else {
                    if let vc = self.notificationsVc {
                        self.show(controller: vc)
                    } else {
                        let vc = NotificationsListViewController()
                        self.notificationsVc = vc
                        self.show(controller: vc)
                    }
                }
                
            case "contacts":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.contactsVc {
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyContact
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                } else {
                    let vc = ContactsViewController()
                    self.contactsVc = vc
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyContact
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                 }
            case "archive":
                if let vc = self.archivedVc {
                    vc.filter.accept(.archived)
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyChat
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                } else {
                    let vc = LastChatsViewController()
                    vc.shouldShowBottomBar = false
                    vc.filter.accept(.archived)
                    self.archivedVc = vc
                    self.show(controller: vc)
                    let svc = EmptyChatViewController()
                    svc.kind = .emptyChat
                    self.splitViewController?.showDetailViewController(UINavigationController(rootViewController: svc), sender: self)
                }
            case "saved":
                if self.chatsVc?.filter.value == .unread {
                    self.chatsVc?.filter.accept(.chats)
                }
                if self.archivedVc?.filter.value == .unread {
                    self.archivedVc?.filter.accept(.archived)
                }
                if let vc = self.chatsVc {
                    vc.filter.accept(LastChatsViewController.Filter.chats)
                    self.show(controller: vc)
                } else {
                    let vc = LastChatsViewController()
                    self.chatsVc = vc
                    vc.filter.accept(LastChatsViewController.Filter.chats)
                    self.show(controller: vc)
                }
            default:
                break
        }
    }
}
