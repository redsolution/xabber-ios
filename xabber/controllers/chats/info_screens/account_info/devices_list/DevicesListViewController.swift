//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
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
            case broken
            case button
            case session
        }
        
        var kind: Kind
        var title: String
        var value: String?
        var date: Date
        var status: ResourceStatus
        var editable: Bool
        var current: Bool
        var childs: [Datasource]
        var verificationSid: String?
        var verificationFullJid: String?
        
        init(_ kind: Kind, title: String, value: String? = nil, date: Date = Date(), status: ResourceStatus = .offline, current: Bool = false, editable: Bool, verificationSid: String? = nil, verificationFullJid: String? = nil, childs: [Datasource] = []) {
            self.kind = kind
            self.title = title
            self.value = value
            self.status = status
            self.date = date
            self.current = current
            self.editable = editable
            self.verificationSid = verificationSid
            self.verificationFullJid = verificationFullJid
            self.childs = childs
        }
    }
    
//    internal var jid: String = ""
    
    internal var datasource: [Datasource] = []
    internal var account: AccountStorageItem = AccountStorageItem()
    internal var bag: DisposeBag = DisposeBag()
    
    internal var devices: Array<DeviceStorageItem> = []
    internal var currentDevice: String = ""
    internal var deviceInstance: DeviceStorageItem? = nil
    internal var omemoDevices: Array<SignalDeviceStorageItem> = []
    internal var brokenOmemoDevices: Array<SignalDeviceStorageItem> = []
    internal var omemoBundles: [SignalIdentityStorageItem] = []
    internal var activeVerificationSession: VerificationSessionStorageItem? = nil
    
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
            currentDevice = account.deviceUuid
            devices = realm
                .objects(DeviceStorageItem.self)
                .filter("owner == %@ AND uid != %@", jid, currentDevice)
                .sorted(byKeyPath: "authDate", ascending: false)
                .toArray()
            omemoDevices = realm
                .objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid == %@", jid, jid)
                .toArray()
            deviceInstance = realm.object(
                ofType: DeviceStorageItem.self,
                forPrimaryKey: DeviceStorageItem.genPrimary(
                    uid: currentDevice, owner: self.jid
                )
            )
            omemoBundles = realm
                .objects(SignalIdentityStorageItem.self)
                .filter("owner == %@ AND jid == %@", jid, jid)
                .toArray()
            
            activeVerificationSession = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.jid, self.jid).first
            
            self.brokenOmemoDevices = omemoDevices.filter {
                device in
                return !(devices.contains(where: {
                    $0.omemoDeviceId == device.deviceId
                })) && (device.deviceId != AccountManager.shared.find(for: self.jid)?.omemo.localStore.localDeviceId() ?? 0)
            }
        } catch {
            DDLogDebug("cant load info about account \(jid)")
        }
    }
    
    internal func update() {
        datasource = [Datasource(.current,
                                 title: "This device".localizeString(id: "settings_account__label_current_session", arguments: []),
                                 value: "Logs out all devices except this one.".localizeString(id: "settings_account_label_log_out_all", arguments: []),
                                 editable: false,
                                 childs: [Datasource(.token,
                                                     title: " ",
                                                     value: account.resource?.resource ?? "",
                                                     editable: false),
                                          Datasource(.button, title: "Terminate all other sessions".localizeString(id: "account_terminate_all_sessions", arguments: []), editable: false)])
        ]
        
        if activeVerificationSession != nil {
            var text: String
            var secondaryText, buttonTitle, buttonKey: String?
            
            (text, secondaryText, buttonTitle, buttonKey) = TrustedDevicesViewController.getCellPropertiesForVerificationSession(verificationState: self.activeVerificationSession!.state)
            
            datasource.append(Datasource(.session, title: "", value: "", editable: false, childs: [
                Datasource(.session, title: text, value: secondaryText, editable: false)
            ]))
            
            if buttonKey != nil {
                datasource[1].childs.append(Datasource(.button, title: buttonTitle!, value: buttonKey, editable: false, verificationSid: activeVerificationSession!.sid, verificationFullJid: activeVerificationSession!.fullJID))
                if buttonKey == "show_verification_code" || buttonKey == "enter_verification_code" {
                    datasource[1].childs.append(Datasource(.button, title: "Cancel", value: "cancel_verification", editable: false, verificationSid: activeVerificationSession!.sid, verificationFullJid: activeVerificationSession!.fullJID))
                } else if buttonKey == "accept_verification" {
                    datasource[1].childs.append(Datasource(.button, title: "Reject", value: "reject_verification", editable: false, verificationSid: activeVerificationSession!.sid, verificationFullJid: activeVerificationSession!.fullJID))
                }
            }
        }
        
        if devices.isNotEmpty {
            datasource.append(Datasource(.token,
                                         title: "Active devices".localizeString(id: "settings_account__label_active_sessions", arguments: []),
                                         value: "You can terminate sessions you don`t need. Official Clandestino clients wipe all user data from the device upon session termination.".localizeString(id: "account_settings_terminate_description", arguments: []),
                       editable: false,
                       childs: []))
        }
        
        if brokenOmemoDevices.isNotEmpty {
            datasource.append(Datasource(
                .broken,
                title: "Obsolete devices",
                value: "Incorrectly published encryption keys. Something went  wrong. You should not be seeing this section. If you do, please, delete these devices.",
                editable: false,
                childs: []))
        }
        
        datasource.append(Datasource(
            .button,
            title: "",
            editable: false,
            childs: [Datasource(.button, title: "Quit account", value: "quit", editable: false)]
        ))
    }
    
    internal func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try Realm()
            
            Observable
                .changeset(from: realm
                    .objects(DeviceStorageItem.self)
                    .filter("owner == %@ AND uid != %@", jid, currentDevice)
                    .sorted(byKeyPath: "authDate", ascending: false))
//                .skip(1)
//                .debounce(.milliseconds(220), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.load()
                    self.update()
                    self.tableView.reloadData()
                })
                .disposed(by: bag)
            Observable
                .changeset(from: realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@", jid, jid))
                .skip(1)
//                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { (results) in
                    self.load()
                    self.update()
                    self.tableView.reloadData()
                })
                .disposed(by: bag)
            
            let verificationSessions = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.jid, self.jid)
            Observable
                .collection(from: verificationSessions)
                .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                DispatchQueue.main.async {
                    self.load()
                    self.tableView.reloadData()
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)
        } catch {
            DDLogDebug("DevicesListViewController: \(#function). \(error.localizedDescription)")
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
    
    
    let refreshControl = UIRefreshControl()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        activateConstraints()
        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
            AccountManager.shared.find(for: self.jid)?.omemo.getContactDevices(stream, jid: self.jid, force: true)
            session.devices?.requestList(stream)
        } fail: {
            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                user.omemo.getContactDevices(stream, jid: self.jid, force: true)
                user.devices.requestList(stream)
            })
        }

        refreshControl.attributedTitle = NSAttributedString(string: "Pull to refresh")
        refreshControl.addTarget(self, action: #selector(self.refresh), for: .valueChanged)
        tableView.addSubview(refreshControl)
        
    }
    
    @objc
    private func refresh(_ sender: AnyObject) {
        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
            AccountManager.shared.find(for: self.jid)?.omemo.getContactDevices(stream, jid: self.jid, force: true)
            session.devices?.requestList(stream)
        } fail: {
            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                user.devices.requestList(stream)
            })
        }
        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
            user.devices.requestList(stream)
        })
        refreshControl.endRefreshing()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscribe()
        title = "Devices".localizeString(id: "account_settings_devices", arguments: [])
        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })
        
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
