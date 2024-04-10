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
                    XMPPNotificationsManager.Category.mention.rawValue,
                    XMPPNotificationsManager.Category.contact.rawValue,
                    XMPPNotificationsManager.Category.trust.rawValue
                ]).sorted(byKeyPath: "date", ascending: false)
            self.datasource = [
                mapResult(allNotifications, title: "", key: "all"),
//                mapResult(readNotifications, title: "Displayed notifgication", key: "read")
            ].compactMap({ return $0.childs.isNotEmpty ? $0 : nil })
            
//            var sortedDatasource: [Datasource] = []
//            for item in self.datasource {
//                let childs = item.childs.sorted(by: { $0.date > $1.date })
//                sortedDatasource.append(Datasource(title: item.title, key: item.key, childs: childs))
//            }
//            
//            self.datasource = sortedDatasource
            
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
                    do {
                        let realm = try WRealm.safe()
                        guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: item.verificationSid!)) else {
//                              let localStore = AccountManager.shared.find(for: owner)?.omemo.localStore else {
                            return nil
                        }
//                        var deviceID = localStore.localDeviceId()
//                        deviceID = Int(item.deviceId!)!
                        if item.verificationState == .acceptedRequest && instance.state == .receivedRequest && instance.myDeviceId != Int(item.deviceId!)! {
                            try realm.write {
                                realm.delete(instance)
                                realm.delete(item)
                            }
                            return nil
                        } else if item.verificationState == .rejected && instance.state == .receivedRequest {
                            try realm.write {
                                realm.delete(instance)
                                realm.delete(item)
                            }
                            return nil
                        }
                        if item.verificationState != instance.state {
                            return nil
                        }
                    } catch {
                        fatalError()
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid ?? item.jid,
                        title: item.associatedJid ?? item.jid,
                        message: item.text ?? "",
                        key: item.associatedJid ?? item.jid,
                        date: item.date,
                        category: item.category,
                        verificationState: item.verificationState,
                        verificationSid: item.verificationSid
                    )
                case .contact:
                    guard let jid = item.associatedJid,
                          let nick = item.displayedNick else {
                        return nil
                    }
                    return DatasourceChild(
                        owner: item.owner,
                        jid: item.associatedJid,
                        title: "\(nick)",
                        message: "New subscribtion request from \(jid)",
                        key: jid,
                        date: item.date,
                        category: item.category,
                        verificationState: nil,
                        verificationSid: nil
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
                        category: item.category,
                        verificationState: nil,
                        verificationSid: nil
                    )
                case .mention:
                    return nil
                case .none:
                    return nil
            }
        }))
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
                    self.getAndMapDatasource()
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
            
        }
    }
    
}

extension NotificationsListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        switch item.category {
            case .trust:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: VerificationSessionItemCell.cellName, for: indexPath) as? VerificationSessionItemCell else {
                    fatalError()
                }
                cell.configure(item.jid!, owner: self.owner, username: "username", date: item.date, verificationState: item.verificationState!)
                return cell
            case .contact:
                fatalError()
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
                return tableView.estimatedRowHeight
            case .contact:
                return 84
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
                guard let sid = item.verificationSid,
                      let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                    return
                }
                let agreeAction = UIAlertAction(title: "Accept", style: UIAlertAction.Style.default) { action in
                    guard let code = akeManager.acceptVerificationRequest(jid: item.jid!, sid: sid) else {
                        return
                    }
                    self.loadDatasource()
                    self.tableView.reloadData()
                    var isVerificationWithUsersDevice = false
                    if item.jid == self.owner {
                        isVerificationWithUsersDevice = true
                    }
                    let vc = ShowCodeViewController(owner: self.owner, jid: item.jid!, code: code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                    vc.configure()
                    self.present(vc, animated: true)
                }
                let disagreeAction = UIAlertAction(title: "Reject", style: .destructive) { action in
                    akeManager.rejectRequestToVerify(jid: item.jid!, sid: sid)
                    self.loadDatasource()
                    self.tableView.reloadData()
                }
                let alert = UIAlertController(title: "Verification session", message: "Do you want to accept verification request from \(item.jid!)?", preferredStyle: UIAlertController.Style.alert)
                alert.addAction(agreeAction)
                alert.addAction(disagreeAction)
                self.present(alert, animated: true)
                return
            }  else if item.verificationState == .sentRequest {
                return
            } else if item.verificationState == VerificationSessionStorageItem.VerififcationState.acceptedRequest {
                guard let sid = item.verificationSid,
                      let jid = item.jid,
                      let akeManager = AccountManager.shared.find(for: self.owner)?.akeManager else {
                    return
                }
                var code: String
                do {
                    let realm = try WRealm.safe()
                    guard let instance = realm.object(ofType: VerificationSessionStorageItem.self, forPrimaryKey: VerificationSessionStorageItem.genPrimary(owner: self.owner, sid: sid)) else {
                        DDLogDebug("NotificationsListViewController: this instance of VerificationSessionStorageItem is not exist")
                        return
                    }
                    code = instance.code
                } catch {
                    fatalError()
                }
                var isVerificationWithUsersDevice = false
                if item.jid == self.owner {
                    isVerificationWithUsersDevice = true
                }
                let vc = ShowCodeViewController(owner: self.owner, jid: jid, code: code, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                vc.configure()
                self.present(vc, animated: true)
                return
            } else if item.verificationState == .receivedRequestAccept {
                guard let sid = item.verificationSid,
                      let jid = item.jid else {
                    return
                }
                var isVerificationWithUsersDevice = false
                if jid == self.owner {
                    isVerificationWithUsersDevice = true
                }
                let vc = AuthenticationCodeInputViewController(owner: self.owner, jid: jid, sid: sid, isVerificationWithUsersDevice: isVerificationWithUsersDevice)
                self.present(vc, animated: true)
                return
            } else if item.verificationState == .failed || item.verificationState == .rejected || item.verificationState == .trusted {
                guard let sid = item.verificationSid,
                      let jid = item.jid else {
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
