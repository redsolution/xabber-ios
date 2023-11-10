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
import TOInsetGroupedTableView
import CocoaLumberjack

class DeviceDetailViewController: SimpleBaseViewController {
    
    class Datasource: Hashable, Equatable {
        static func == (lhs: DeviceDetailViewController.Datasource, rhs: DeviceDetailViewController.Datasource) -> Bool {
            return lhs.key == rhs.key
        }
        
        var title: String
        var value: String?
        var key: String
        
        init(title: String, value: String?, key: String) {
            self.title = title
            self.value = value
            self.key = key
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
        }
    }
    
    open var uid: String = ""
    open var canEdit: Bool = false
    private var datasource: [[Datasource]] = []
    
    private var omemoDeviceID: Int = -1
    
    private var resource: String? = nil
    private var statusTitle: String? = nil
    private var status: ResourceStatus = .offline
    
    internal var accountResources: Results<ResourceStorageItem>? = nil
    
    open var delegate: XabberUpdateIfNeededDelegate? = nil
    
    private var currentDeviceDescription: String? = nil
    
    internal var dangerInEncryption: Bool = false
    internal var issuedFor: String? = nil
    
    private let tableView: UITableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "ButtonCell")
        view.register(UITableViewCell.self, forCellReuseIdentifier: "DangerCell")
        view.register(StatusInfoCell.self, forCellReuseIdentifier: StatusInfoCell.cellName)
        view.register(ResourceInfoCell.self, forCellReuseIdentifier: ResourceInfoCell.cellName)
        
        view.isScrollEnabled = false
        
        return view
    }()
    
    override func configure() {
        super.configure()
        self.title = "Device information"
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try WRealm.safe()
            guard let deviceInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, jid].prp()) else {
                return
            }
            self.omemoDeviceID = deviceInstance.omemoDeviceId
            let resourceInstance = realm.objects(AccountStorageItem.self).filter("jid == %@", jid)
            
            let deviceTitle = deviceInstance.descr.isNotEmpty ? deviceInstance.descr : deviceInstance.client
            let deviceDescr = deviceInstance.descr.isNotEmpty ? deviceInstance.descr : nil
            
            self.currentDeviceDescription = deviceDescr
            self.resource = deviceInstance.resource
            
            if let resource = self.resource {
                if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: self.jid, owner: self.jid, resource: resource)) {
                    self.statusTitle = instance.displayedStatus
                    self.status = instance.status
                }
            }
            
            var encryptionDatasource: [Datasource] = [
                Datasource(title: "Bundle not found", value: "", key: "omemo_bundle_not_found")
            ]
            
            if deviceInstance.encryptionEnabled {
                
                if let omemoDevice = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: deviceInstance.omemoDeviceId)),
                   realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: self.owner, jid: self.jid, deviceId: deviceInstance.omemoDeviceId)) != nil {
                    var trustElement: Datasource
                    switch omemoDevice.state {
                    case .Ignore:
                        trustElement = Datasource(title: "Device ignored", value: "Ignored", key: "omemo_state_ignore")
                    case .trusted:
                            trustElement = Datasource(
                                title: omemoDevice.isTrustedByCertificate ? "Device signed" : "Device trusted",
                                value: omemoDevice.isTrustedByCertificate ? "Signed" : "Trusted",
                                key: "omemo_state_trusted"
                            )
                    case .fingerprintChanged:
                        trustElement = Datasource(title: "Fingerprint changed", value: "Fingerprint changed", key: "omemo_state_fingerprint_changed")
                    case .unknown:
                        trustElement = Datasource(title: "Action required", value: "Undefined", key: "omemo_state_undefined")
                    }
                    encryptionDatasource = [
                        Datasource(title: "Device ID", value: "\(omemoDevice.deviceId)", key: "omemo_deviceId"),
                        Datasource(title: "Fingerprint", value: omemoDevice.fingerprint, key: "omemo_fingerprint")
                        
                    ]
                    if omemoDevice.signature != nil {
                        self.dangerInEncryption = omemoDevice.signedBy != self.jid
                        self.issuedFor = omemoDevice.signedBy
                        encryptionDatasource.append(
                            Datasource(
                                title: omemoDevice.signedBy == self.jid ? "Verified by" : "Not verified",
                                value: omemoDevice.signedBy == self.jid ? "Clandestino" : "",
                                key: "omemo_signed_by"
                            )
                        )
                    }
                    if !canEdit {
                        encryptionDatasource.append(trustElement)
                    }
                }
            }
            
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy HH:mm"
            if canEdit {
                datasource = [
                    [
                        Datasource(title: "Device", value: deviceTitle, key: "title"),
//                        Datasource(title: "Description", value: deviceDescr, key: "descr")
                    ],
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value:  dateFormatter.string(from: deviceInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: deviceInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "device__info__client__label", arguments: []),
                                   value: deviceInstance.client, key: "client"),
                        Datasource(title: "Resource".localizeString(id: "account_resource", arguments: []),
                                   value: resourceInstance.first?.resource?.resource, key: "resource"),
                        Datasource(title: "IP", value: deviceInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.expire), key: "expire")
                    ],
                    encryptionDatasource,
                    [
                        Datasource(title: "Rename".localizeString(id: "input_widget__button_rename", arguments: []),
                                   value: nil, key: "rename")
                    ],
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []),
                                   value: nil, key: "terminate")
                    ],
                ]
            } else {
                datasource = [
                    [
                        Datasource(title: "Last seen".localizeString(id: "device__info__status__label_last_seen", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.authDate), key: "status"),
                        Datasource(title: "Device".localizeString(id: "device", arguments: []),
                                   value: deviceInstance.device, key: "device"),
                        Datasource(title: "Client".localizeString(id: "contact_viewer_client", arguments: []),
                                   value: deviceInstance.client, key: "client"),
                        Datasource(title: "IP", value: deviceInstance.ip, key: "ip"),
                        Datasource(title: "Expires at".localizeString(id: "device__info__expire__label", arguments: []),
                                   value: dateFormatter.string(from: deviceInstance.expire), key: "expire")
                    ],
                    encryptionDatasource,
                    [
                        Datasource(title: "Terminate session".localizeString(id: "device__info__terminate_session__button", arguments: []), value: nil, key: "terminate")
                    ],
                ]
            }
        } catch {
            DDLogDebug("TokenInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    private final func onRename() {
        TextViewPresenter().present(
            in: self,
            title: "Rename device".localizeString(id: "device_info_rename_device", arguments: []),
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Rename".localizeString(id: "device__info__rename__button", arguments: []),
            currentValue: self.currentDeviceDescription,
            animated: true) { value in
            if value != self.currentDeviceDescription {
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.update(stream, descr: value)
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.update(stream, descr: value)
                    })
                }
            }
            DispatchQueue.main.async {
                self.goBack()
            }
        }
    }
    
    private final func onTerminate() {
        let items = [
            ActionSheetPresenter.Item(destructive: true, title: "Terminate session?".localizeString(id: "device__info__terminate_session__button", arguments: []), value: "terminate")
        ]
        
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: items,
            animated: true) { value in
            switch value {
            case "terminate":
                XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                    session.devices?.revoke(stream, uids: [self.uid])
                } fail: {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.devices.revoke(stream, uids: [self.uid])
                    })
                }
            default:
                break
            }
            DispatchQueue.main.async {
                self.goBack()
            }
        }
    }
}

extension DeviceDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "omemo_fingerprint":
            return 84
        default:
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "rename":
            onRename()
        case "terminate":
            onTerminate()
        case "status":
            do {
                let realm = try WRealm.safe()
                if let resource = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: DeviceStorageItem.genPrimary(uid: self.uid, owner: self.jid))?.resource {
                    let vc = ContactInfoResourceController()
                    vc.jid = self.jid
                    vc.owner = self.jid
                    vc.resource = resource
                    vc.isModal = true
                    let nvc = UINavigationController(rootViewController: vc)
                    nvc.modalPresentationStyle = .fullScreen
                    nvc.modalTransitionStyle = .coverVertical
                    self.definesPresentationContext = true
                    self.present(nvc, animated: true, completion: nil)
                }
            } catch {
                DDLogDebug("TokenInfoViewController: \(#function). \(error.localizedDescription)")
            }
        case "resource":
            let vc = AccountConnectionViewController()
            vc.configure(for: jid)
            
            let nvc = UINavigationController(rootViewController: vc)
            nvc.modalPresentationStyle = .fullScreen
            nvc.modalTransitionStyle = .coverVertical
            self.definesPresentationContext = true
            self.present(nvc, animated: true, completion: nil)
        case "omemo_signed_by":
            if self.dangerInEncryption {
                ActionSheetPresenter().present(
                    in: self,
                    title: "Encription not secured",
                    message: "Encryption key signed by certificate issued for \(self.issuedFor ?? "unknown user")",
                    cancel: "Close",
                    values: [],
                    animated: true) { _ in
                        
                    }
            } else {
                ActionSheetPresenter().present(
                    in: self,
                    title: "Encription secured",
                    message: "Encryption key verified by certificate issued by Clandestino for \(self.issuedFor ?? "")",
                    cancel: "Close",
                    values: [],
                    animated: true) { _ in
                        
                    }
            }
            
        case "omemo_state_trusted":
            let items: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: true, title: "Delete", value: "delete")
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Untrust this device",
                message: nil,
                cancel: "Cancel",
                values: items,
                animated: true) { value in
                    switch value {
                    case "trust":
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) {
                                try realm.write {
                                    instance.state = .trusted
                                }
                            }
                            
                            DispatchQueue.main.async {
                                self.goBack()
                            }
                        } catch {
                            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
                        }
                    case "delete":
                        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                            session.devices?.revoke(stream, uids: [self.uid])
                        } fail: {
                            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                                user.devices.revoke(stream, uids: [self.uid])
                            })
                        }
                        DispatchQueue.main.async {
                            self.goBack()
                        }
                    default:
                        break
                    }
                }
        case "omemo_state_fingerprint_changed", "omemo_state_undefined":
            let items: [ActionSheetPresenter.Item] = [
                ActionSheetPresenter.Item(destructive: false, title: "Trust", value: "trust"),
                ActionSheetPresenter.Item(destructive: true, title: "Delete device", value: "delete")
            ]
            ActionSheetPresenter().present(
                in: self,
                title: "Trust this device",
                message: nil,
                cancel: "Cancel",
                values: items,
                animated: true) { value in
                    switch value {
                    case "trust":
                        do {
                            let realm = try Realm()
                            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: self.omemoDeviceID)) {
                                try realm.write {
                                    instance.state = .trusted
                                }
                            }
                            
                            DispatchQueue.main.async {
                                self.goBack()
                            }
                        } catch {
                            DDLogDebug("DeviceDetailViewController: \(#function). \(error.localizedDescription)")
                        }
                    case "delete":
                        XMPPUIActionManager.shared.performRequest(owner: self.jid) { stream, session in
                            session.devices?.revoke(stream, uids: [self.uid])
                        } fail: {
                            AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                                user.devices.revoke(stream, uids: [self.uid])
                            })
                        }
                        DispatchQueue.main.async {
                            self.goBack()
                        }
                    default:
                        break
                    }
                }
        default:
            break
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

extension DeviceDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.key {
        case "terminate":
            let cell = tableView.dequeueReusableCell(withIdentifier: "DangerCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemRed
            return cell
        case "rename":
            let cell = tableView.dequeueReusableCell(withIdentifier: "ButtonCell", for: indexPath)
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemBlue
            return cell
        case "status":
            if self.resource != nil {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: StatusInfoCell.cellName, for: indexPath) as? StatusInfoCell else {
                    fatalError()
                }
                
                cell.configure(
                    title: self.statusTitle ?? "Offline".localizeString(id: "unavailable", arguments: []),
                    status: self.status,
                    entity: .contact,
                    isTemporary: false
                )
                
                return cell
            } else {
                let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
                cell.textLabel?.text = item.title
                cell.detailTextLabel?.text = item.value
                return cell
            }
        case "resource":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.value
            cell.accessoryType = .disclosureIndicator
            return cell
            
        case "omemo_state_ignore":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemGray
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemGray
            
            return cell
        case "omemo_state_trusted":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemGreen
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemGreen
            
            return cell
        case "omemo_state_fingerprint_changed":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemOrange
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemOrange
            
            return cell
        case "omemo_state_undefined":
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.textLabel?.textColor = .systemOrange
            cell.accessoryType = .none
            cell.imageView?.image = UIImage(named: "security")?.withRenderingMode(.alwaysTemplate)
            cell.imageView?.tintColor = .systemOrange
            
            return cell
        case "omemo_fingerprint":
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.value
            cell.detailTextLabel?.numberOfLines = 2
            if #available(iOS 13.0, *) {
                cell.detailTextLabel?.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .light)
            } else {
                // Fallback on earlier versions
            }
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        default:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleCell")
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = item.value
            return cell
        }
    }
    
}
