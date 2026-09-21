//
//  AccountTokensViewController.swift
//  xabber_test_xmpp
//
//  Created by Igor Boldin on 14/06/2019.
//  Copyright © 2019 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import RxRealm
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import TOInsetGroupedTableView

class DevicesListViewController: BaseViewController {
    class Datasource {
        enum Kind {
            case current
            case token
            case button
        }
        
        var kind: Kind
        var title: String
        var value: String
        var date: Date
        var status: ResourceStatus
        var editable: Bool
        var current: Bool
        var childs: [Datasource]
        
        init(_ kind: Kind, title: String, value: String = "", date: Date = Date(), status: ResourceStatus = .offline, current: Bool = false, editable: Bool, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.date = date
            self.current = current
            self.editable = editable
            self.childs = childs
        }
    }
    
//    internal var jid: String = ""
    
    internal var datasource: [Datasource] = []
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var bag: DisposeBag = DisposeBag()
    
    internal var tokens: Results<DeviceStorageItem>? = nil
    internal var currentToken: String = ""
    internal var tokenInstance: DeviceStorageItem? = nil
    
    internal let tableView: UITableView = {
//        let view = UITableView(frame: .zero, style: .grouped)
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        
        return view
    }()
    
    internal var editButton: UIBarButtonItem? = nil
    internal var doneEditButton: UIBarButtonItem? = nil
    
    func load() {
        do {
            let realm = try WRealm.safe()
            account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) ?? AccountStorageItem()
            currentToken = account.xTokenUID
            tokens = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid != %@", jid, currentToken).sorted(byKeyPath: "authDate", ascending: false)
            tokenInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: currentToken, owner: self.jid))
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func update() {
        datasource = [Datasource(.current,
                                 title: L10n.text("settings_account__label_current_session", fallback: "This device"),
                                 value: L10n.text("settings_account_label_log_out_all", fallback: "Logs out all devices except this one"),
                                 editable: false,
                                 childs: [Datasource(.token,
                                                     title: " ",
                                                     value: account.resource?.resource ?? "",
                                                     editable: false),
                                          Datasource(.button, title: L10n.text("account_terminate_all_sessions", fallback: "Terminate all other sessions"), editable: false)])
        ]
        if !(tokens?.isEmpty ?? true) {
            datasource.append(Datasource(.token,
                                         title: L10n.text("settings_account__label_active_sessions", fallback: "Active sessions"),
                                         value: L10n.text("account_settings_terminate_description", fallback: "You can terminate sessions you don`t need. Official Xabber clients wipe all user data from the device upon session termination."), /* learn more - https://www.xabber.com/devicemanagement/   */
                       editable: false,
                       childs: []))
        }
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        
        if tokens != nil {
            Observable
                .changeset(from: tokens!)
                .subscribe(onNext: { (results) in
                    self.load()
                    self.update()
                    self.tableView.reloadData()
                })
                .disposed(by: bag)
        }
        
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
    }
    
    internal func activateConstraints() {
        
    }
    
    open func configure(for jid: String) {
        self.jid =  jid
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.delegate = self
        tableView.dataSource = self
        hideKeyboardWhenTappedAround()
        load()
        update()
        editButton = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(self.onEdit))
        doneEditButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.onDoneEditing))
        navigationItem.setRightBarButton(editButton, animated: true)
    }
    
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        activateConstraints()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        title = L10n.text("account_settings_devices", fallback: "Devices")
        //navigationController?.title = "Devices".localizeString(id: "account_settings_devices", arguments: [])
        XMPPUIActionManager.shared.open(owner: self.jid)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        //title = " "
        //navigationController?.title = " "
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    @objc
    internal func onEdit(sender: AnyObject) {
        self.tableView.setEditing(true, animated: true)
        navigationItem.setRightBarButton(doneEditButton, animated: true)
    }
    
    @objc
    internal func onDoneEditing(sender: AnyObject) {
        self.tableView.setEditing(false, animated: true)
        navigationItem.setRightBarButton(editButton, animated: true)
    }
}
