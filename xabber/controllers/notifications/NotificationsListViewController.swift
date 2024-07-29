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
    
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(DeviceItemCell.self, forCellReuseIdentifier: DeviceItemCell.cellName)
        view.register(VerificationSessionItemCell.self, forCellReuseIdentifier: VerificationSessionItemCell.cellName)
        
        view.separatorStyle = .none
        
        view.allowsSelection = true
        
        return view
    }()
    
    internal let emptyView: EmptyView = {
        let view = EmptyView()
        
        return view
    }()
    
    struct Datasource {
        let title: String
        let key: String
        let childs: [DatasourceChild]
    }
    
    struct DatasourceChild {
        let owner: String
        let jid: String
        let title: String
        let message: String?
        let key: String?
        let date: Date?
        let category: XMPPNotificationsManager.Category
        let avatarUrl: String?
        let verificationState: VerificationSessionStorageItem.VerififcationState?
        let verificationSid: String?
    }
    
    var datasource: [Datasource] = []
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
        
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
    
    /*Datasource(title: "All", icon: "bell.fill", key: "all", subtitle: "\(0)"),
     Datasource(title: "Security", icon: "exclamationmark.shield.fill", key: "security", subtitle: "\(0)"),
     Datasource(title: "Subscribtion requests", icon: "person.crop.circle.fill.badge.plus", key: "subscribtion", subtitle: "\(0)"),
     Datasource(title: "Information", icon: "info.circle.fill", key: "info", subtitle: "\(0)")*/
    
    enum Filter {
        case all
        case security
        case information
    }
    
    var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .all)
    var filterMenu: UIMenu = UIMenu()
    func configureBars() {
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .done, target: self, action: nil)
                
                filterMenu = UIMenu(options: [.singleSelection], children: [
                    UIAction(
                        title: "All",
                        image: UIImage(systemName: "bell.fill"),
                        identifier: .none,
                        discoverabilityTitle: "Displays all notifications",
                        attributes: [],
                        state: .mixed, //filter.value == .all ? .on : .off,
                        handler: { action in
                            self.filter.accept(.all)
                        }),
                    UIAction(
                        title: "Security",
                        image: UIImage(systemName: "exclamationmark.shield.fill"),
                        identifier: .none,
                        discoverabilityTitle: nil,
                        attributes: [],
                        state: filter.value == .security ? .on : .off,
                        handler: { action in
                            self.filter.accept(.security)
                        }),
                    UIAction(
                        title: "Information",
                        image: UIImage(systemName: "info.circle.fill"),
                        identifier: .none,
                        discoverabilityTitle: nil,
                        attributes: [],
                        state: filter.value == .information ? .on : .off,
                        handler: { action in
                            self.filter.accept(.information)
                        }),
                ])
                
//                filterMenu
                
                button.menu = filterMenu
                self.navigationItem.setRightBarButton(button, animated: true)
            case .split:
                break
        }
    }
    
    func getAndMapDatasource() {
        let jids = AccountManager.shared.users.map { $0.jid }
        
        do {
            let realm = try WRealm.safe()
            let allNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("owner IN %@ AND category_ IN %@", jids, [
                    XMPPNotificationsManager.Category.device.rawValue,
                    XMPPNotificationsManager.Category.mention.rawValue,
                    XMPPNotificationsManager.Category.trust.rawValue
                ]).sorted(byKeyPath: "date", ascending: false)
            let contactNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("owner IN %@ AND category_ IN %@", jids, [
                    XMPPNotificationsManager.Category.contact.rawValue
                ])
            
            self.datasource = [
                mapResult(contactNotifications, title: "Subscription requests", key: "contact"),
                mapResult(allNotifications, title: "All", key: "all"),
            ].compactMap({ return $0.childs.isNotEmpty ? $0 : nil })

            self.emptyScreenShowObserver.accept(self.datasource.isEmpty)
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func mapResult(_ results: Results<NotificationStorageItem>, title: String, key: String) -> Datasource {
        return Datasource(title: title, key: key, childs: results.compactMap({
            (item) -> DatasourceChild? in
            switch item.category {
                case .trust:
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!)) {
                            
                            if item.verificationState == .acceptedRequest && instance.state == .receivedRequest && instance.myDeviceId != Int(item.deviceId!)! {
                                //                            try realm.write {
                                //                                realm.delete(instance)
                                //                                realm.delete(item)
                                //                            }
                                return nil
                            } else if item.verificationState == .rejected && instance.state == .receivedRequest {
                                //                            try realm.write {
                                //                                realm.delete(instance)
                                //                                realm.delete(item)
                                //                            }
                                return nil
                            }
                            if item.verificationState != instance.state {
                                return nil
                            }
                        }
                    } catch {
                        DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid ?? item.jid,
                        title: item.associatedJid ?? item.jid,
                        message: item.text ?? "",
                        key: item.uniqueId,
                        date: item.date,
                        category: item.category, avatarUrl: nil,
                        verificationState: item.verificationState,
                        verificationSid: item.verificationSid
                    )
                case .contact:
                    guard let jid = item.associatedJid,
                          let nick = item.displayedNick ?? item.associatedJid else {
                        return nil
                    }
                
                    var askMessage: String? = nil
                    var avatarUrl: String? = nil
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: "\(jid)_\(item.owner)") {
                            if instance.ask == .none {
                                return nil
                            }
                            
                            askMessage = instance.askMessage == "" ? nil : instance.askMessage
                            avatarUrl = instance.avatarUrl
                        }
                        
                    } catch {
                        DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                    }
                
                    return DatasourceChild(
                        owner: item.owner,
                        jid: jid,
                        title: nick,
                        message: askMessage,
                        key: nil,
                        date: nil,
                        category: item.category,
                        avatarUrl: avatarUrl,
                        verificationState: nil,
                        verificationSid: nil
                    )
                
                case .device:
                    guard let deviceId = item.metadata?["deviceId"] as? String else {
                        return nil
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid ?? item.jid,
                        title: "New device login",
                        message: item.text ?? " ",//"Detected new login from \(ip) by \(client) on \(device) device",
                        key: deviceId,
                        date: item.date,
                        category: item.category,
                        avatarUrl: nil,
                        verificationState: nil,
                        verificationSid: nil
                    )
                case .mention:
                    return nil
                case .none:
                    return nil
            }
        }) ?? [])
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
            let collectionObserver = realm.objects(NotificationStorageItem.self).filter("owner IN %@", jids)
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
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
            
            let rosterObserver = realm.objects(RosterStorageItem.self).filter("owner IN %@ AND ask_ == %@", jids, RosterStorageItem.Ask.in.rawValue)
            Observable
                .collection(from: rosterObserver)
                .subscribe { _ in
                    self.loadDatasource()
                    self.tableView.reloadData()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)

            
        } catch {
            
        }
    }
    
}

extension NotificationsListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.datasource[section].key == "contact" {
            return self.datasource[section].childs.count
        }
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: VerificationSessionItemCell.cellName, for: indexPath) as? VerificationSessionItemCell,
                      let date = item.date else {
                    return UITableViewCell(frame: .zero)
                }
            
                cell.configure(item.jid, owner: self.owner, username: "username", date: date, verificationState: item.verificationState!)
                cell.accessoryType = .disclosureIndicator
                
                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
                cell.selectedBackgroundView = view
                
                return cell
            case .contact:
                let cell = ContactItemCell()
                cell.configure(owner: item.owner, username: item.title, jid: item.jid, message: item.message, avatarUrl: item.avatarUrl)
            
            cell.addButtonAction = {
                AccountManager.shared.find(for: item.owner)?.action({ user, stream in
                    user.presences.subscribed(stream, jid: item.jid, storePreaproved: false)
                    self.loadDatasource()
                    
                    DispatchQueue.main.async {
                        self.tableView.reloadData()
                    }
                })
            }
            
            cell.declineButtonAction = {
                AccountManager.shared.find(for: item.owner)?.action({ user, stream in
                    user.presences.unsubscribed(stream, jid: item.jid)
                    self.loadDatasource()
                    
                    DispatchQueue.main.async {
                        self.tableView.reloadData()
                    }
                })
            }
                
                return cell
//                guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactItemCell.cellName, for: indexPath) as? ContactItemCell else {
//                    fatalError()
//                }
//                
//                let message_more = "\(self.datasource[indexPath.section].childs.first?.title ?? "undefined")"
//                
//                let message = "\(self.datasource[indexPath.section].childs.first?.title ?? "undefined") sent a subscri"
//            cell.configure(owner: item.owner, username: item.title, title: item.title, message: item.message )
//                
////                cell.collectionView.delegate = self
////                cell.collectionView.dataSource = self
////                
//                cell.accessoryType = .disclosureIndicator
//                
//                let view = UIView()
//                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
//                cell.selectedBackgroundView = view
//                
//                return cell
            case .device:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceItemCell.cellName, for: indexPath) as? DeviceItemCell else {
                    fatalError()
                }
                
                cell.configure(
                    item.jid ?? item.owner,
                    owner: item.owner,
                    avatarUrl: nil,
                    customImage: nil,
                    username: item.jid ?? item.owner,
                    title: "New login to server \(item.jid)",
                    message: item.message ?? "",
                    date: item.date,
                    positiveButtonTitle: "Verify",
                    negativeButtonTitle: "Revoke"
                )
                
//                cell.configure("", owner: self.owner, username: XMPPJID(string: self.owner)?.domain ?? self.owner, title: item.title, message: item.message, date: item.date)
//                cell.accessoryType = .disclosureIndicator
                
                
                let view = UIView()
                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50
                cell.selectedBackgroundView = view
                
                return cell
            case .mention:
                fatalError()
            case .none:
                fatalError()
        }
    }
    
//    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
//        return self.datasource[section].title
//    }
}

extension NotificationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
                return tableView.estimatedRowHeight
            case .contact:
                return tableView.estimatedRowHeight
            case .device:
                return tableView.estimatedRowHeight
            case .mention:
                return 84
            case .none:
                return 84
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
            if item.verificationState == .receivedRequest {
//                let agreeAction = UIAlertAction(title: "Accept", style: UIAlertAction.Style.default) { action in
//                    guard let code = AccountManager.shared.find(for: self.owner)?.akeManager.acceptVerificationRequest(jid: item.jid!, sid: item.verificationSid ?? "") else {
//                        return
//                    }
//                    do {
//                        let realm = try WRealm.safe()
//                        try realm.write {
//                            realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: self.owner, jid: item.jid!, uniqueId: item.key))?.verificationState = .acceptedRequest
//                        }
//                    } catch {
//                        DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
//                    }
//                    let vc = ShowCodeViewController()
//                    vc.jid = item.jid ?? ""
//                    vc.owner = item.owner
//                    vc.code = code
//                    vc.sid = item.verificationSid ?? ""
//                    vc.isVerificationWithOwnDevice = item.jid == item.owner
//                    self.present(vc, animated: true)
//                }
//                let disagreeAction = UIAlertAction(title: "Reject", style: .destructive) { action in
//                    AccountManager.shared.find(for: self.owner)?.akeManager.rejectRequestToVerify(jid: item.jid!, sid: item.verificationSid ?? "")
//                    self.loadDatasource()
//                    self.tableView.reloadData()
//                }
//                let alert = UIAlertController(title: "Verification session", message: "Do you want to accept verification request from \(item.jid!)?", preferredStyle: UIAlertController.Style.alert)
//                alert.addAction(agreeAction)
//                alert.addAction(disagreeAction)
//                self.present(alert, animated: true)
                return
            }  else if item.verificationState == .sentRequest {
                return
            } else if item.verificationState == VerificationSessionStorageItem.VerififcationState.acceptedRequest {
//                do {
//                    let realm = try WRealm.safe()
//                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid ?? ""))
//                    let vc = ShowCodeViewController()
//                    vc.jid = item.jid ?? ""
//                    vc.owner = item.owner
//                    vc.code = instance?.code ?? ""
//                    vc.sid = item.verificationSid ?? ""
//                    vc.isVerificationWithOwnDevice = item.jid == item.owner
//                    self.present(vc, animated: true)
//                } catch {
//                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
//                }
            } else if item.verificationState == .receivedRequestAccept {
//                let vc = AuthenticationCodeInputViewController()
//                vc.jid = item.jid ?? ""
//                vc.owner = item.owner
//                vc.sid = item.verificationSid ?? ""
//                vc.isVerificationWithUsersDevice = item.jid == item.owner
//                self.present(vc, animated: true)
            } else if item.verificationState == .failed || item.verificationState == .rejected || item.verificationState == .trusted {
                guard let sid = item.verificationSid else {
                    return
                }
                do {
                    let realm = try WRealm.safe()
                    let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid))
                    try realm.write {
                        realm.delete(instance!)
                    }
                } catch {
                    fatalError()
                }
                
                var alertMessage = ""
                if item.verificationState == .failed {
                    alertMessage = "Verification session with \(jid) failed.\nSID: \(item.verificationSid!)"
                } else if item.verificationState == .rejected {
                    alertMessage = "Verification session with \(jid) rejected.\nSID: \(item.verificationSid!)"
                } else if item.verificationState == .trusted {
                    alertMessage = "Verification session with \(jid) was successful, the device is now trusted.\nSID: \(item.verificationSid!)"
                }
                let action = UIAlertAction(title: "Okay", style: .cancel) { action in
                    self.loadDatasource()
                    self.tableView.reloadData()
                }
                let alert = UIAlertController(title: "", message: alertMessage, preferredStyle: UIAlertController.Style.alert)
                alert.addAction(action)
                self.present(alert, animated: true)
                return
            }
                break
            case .contact:
                break
//                let vc = NotificationsSubscribtionsListViewController()
//                vc.owner = item.owner
//                showStacked(vc, in: self)
//                self.navigationController?.pushViewController(vc, animated: true)
            case .device:
                do {
                    let realm = try WRealm.safe()
                    if let _ = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: item.key ?? "", owner: item.owner)) {
                        let vc = DeviceDetailViewController()
                        vc.owner = item.owner
                        vc.jid = item.owner
                        vc.uid = item.key ?? ""
                        showStacked(vc, in: self)
//                        self.navigationController?.pushViewController(vc, animated: true)
                    } else {
                        let vc = DevicesListViewController()
                        vc.configure(for: item.owner)
                        showStacked(vc, in: self)
//                        self.navigationController?.pushViewController(vc, animated: true)
                    }
                } catch {
                    DDLogDebug("NotificationListViewController: \(#function). \(error.localizedDescription)")
                }
                
            case .mention:
                break
            case .none:
                break
        }
        
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UITableViewHeaderFooterView()
        
        let title = UILabel()
        title.font = .systemFont(ofSize: 20, weight: .medium)
        title.text = self.datasource[section].title
        title.translatesAutoresizingMaskIntoConstraints = false
        
        let separator = UIView()
        separator.backgroundColor = MDCPalette.grey.tint300
        separator.translatesAutoresizingMaskIntoConstraints = false
        
        header.contentView.addSubview(title)
        header.contentView.addSubview(separator)
        
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.contentView.leadingAnchor, constant: 16),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.leftAnchor.constraint(equalTo: header.contentView.leftAnchor, constant: 16),
            separator.rightAnchor.constraint(equalTo: header.contentView.rightAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor)
        ])
        
        return header
        
    }
}

extension NotificationsListViewController: UICollectionViewDataSource {
    
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 1
    }
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if self.datasource[0].key == "contact" {
            return self.datasource[0].childs.count
        }
        return 0
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ContactOldItemCell.ScrollCell.cellName, for: indexPath) as? ContactOldItemCell.ScrollCell else {
            fatalError()
        }
        let item = self.datasource[0].childs[indexPath.item]
        
        cell.configure(owner: item.owner, username: item.title)
        
        return cell
    }
    
    
}

extension NotificationsListViewController: UICollectionViewDelegate {
    
}
