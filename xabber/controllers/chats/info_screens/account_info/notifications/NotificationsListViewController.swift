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
        view.register(ContactItemCell.self, forCellReuseIdentifier: ContactItemCell.cellName)
        
        view.separatorStyle = .none
        
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
        let jid: String?
        let title: String
        let message: String
        let key: String
        let date: Date
        let category: XMPPNotificationsManager.Category
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
        self.title = "Notifications"
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
    
    func getAndMapDatasource() {
        do {
            let realm = try WRealm.safe()
            let allNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("category_ IN %@", [
                    XMPPNotificationsManager.Category.device.rawValue,
                    XMPPNotificationsManager.Category.mention.rawValue
                ])
            let contactNotifications = realm
                .objects(NotificationStorageItem.self)
                .filter("category_ IN %@", [
                    XMPPNotificationsManager.Category.contact.rawValue
                ])
            let contactDatasource = Datasource(title: "", key: "contact", childs: [
                DatasourceChild(
                    owner: "",
                    jid: "",
                    title: "",
                    message: "",
                    key: "",
                    date: Date(),
                    category: .contact
                )
            ])
            self.datasource = [
                mapResult(contactNotifications, title: "", key: "contact"),
                mapResult(allNotifications, title: "", key: "all"),
//                mapResult(readNotifications, title: "Displayed notifgication", key: "read")
            ].compactMap({ return $0.childs.isNotEmpty ? $0 : nil })
            self.emptyScreenShowObserver.accept(self.datasource.isEmpty)
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private func mapResult(_ results: Results<NotificationStorageItem>, title: String, key: String) -> Datasource {
        return Datasource(title: title, key: key, childs: results.compactMap({
            (item) in
            switch item.category {
                case .trust:
                    return nil
                case .contact:
                    guard let jid = item.associatedJid,
                          let nick = item.displayedNick ?? item.associatedJid else {
                        return nil
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid,
                        title: nick,
                        message: "New subscribtion request from \(jid)",
                        key: jid,
                        date: item.date,
                        category: item.category
                    )
                case .device:
                    guard let deviceId = item.metadata?["deviceId"] as? String else {
                        return nil
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid,
                        title: "New device login",
                        message: item.text ?? " ",//"Detected new login from \(ip) by \(client) on \(device) device",
                        key: deviceId,
                        date: item.date,
                        category: item.category
                    )
                case .mention:
                    return nil
                case .none:
                    return nil
            }
        }))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
    }
    
    override func subscribe() {
        super.subscribe()
        
        do {
            let realm = try WRealm.safe()
            let collectionObserver = realm.objects(NotificationStorageItem.self).filter("owner == %@", self.owner)
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.loadDatasource()
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
            
        }
    }
    
}

extension NotificationsListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.datasource[section].key == "contact" {
            return 1
        }
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
                fatalError()
            case .contact:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ContactItemCell.cellName, for: indexPath) as? ContactItemCell else {
                    fatalError()
                }
                
                let message_more = "\(self.datasource[indexPath.section].childs.first?.title ?? "undefined") and  \(self.datasource[indexPath.section].childs.count) contacts more"
                
                let message = "\(self.datasource[indexPath.section].childs.first?.title ?? "undefined") sent a subscri"
                cell.configure(owner: item.owner, username: item.title, title: "Subscribtion requests", message: self.datasource[indexPath.section].childs.count > 1 ? message_more : message )
                
//                cell.collectionView.delegate = self
//                cell.collectionView.dataSource = self
//                
                return cell
            case .device:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceItemCell.cellName, for: indexPath) as? DeviceItemCell else {
                    fatalError()
                }
                
                cell.configure("", owner: self.owner, username: XMPPJID(string: self.owner)?.domain ?? self.owner, title: item.title, message: item.message, date: item.date)
//                cell.accessoryType = .disclosureIndicator
                
                return cell
            case .mention:
                fatalError()
            case .none:
                fatalError()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.datasource[section].title
    }
}

extension NotificationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
                return 84
            case .contact:
                return 74
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
                break
            case .contact:
                let vc = NotificationsSubscribtionsListViewController()
                vc.owner = item.owner
                self.navigationController?.pushViewController(vc, animated: true)
            case .device:
                do {
                    let realm = try WRealm.safe()
                    if let _ = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: item.key, owner: item.owner)) {
                        let vc = DeviceDetailViewController()
                        vc.owner = item.owner
                        vc.jid = item.owner
                        vc.uid = item.key
                        self.navigationController?.pushViewController(vc, animated: true)
                    } else {
                        let vc = DevicesListViewController()
                        vc.configure(for: item.owner)
                        self.navigationController?.pushViewController(vc, animated: true)
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
