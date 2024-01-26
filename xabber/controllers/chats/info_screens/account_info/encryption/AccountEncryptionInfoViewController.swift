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
import TOInsetGroupedTableView
import RealmSwift
import RxRealm
import RxSwift
import RxCocoa
import CocoaLumberjack


class AccountEncryptionInfoViewController: SimpleBaseViewController {
    class Datasource {
        enum Kind {
            case current
            case device
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
    
    private var deviceInstance: SignalDeviceStorageItem? = nil
    private var devices: Results<SignalDeviceStorageItem>? = nil
    
    private var currentDeviceId: UInt32 = 0
    
    private var isEncryptionEnabledObserver: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: true)
    
    private var datasource: [Datasource] = []
    
    let stateSwitch: UISwitch = {
        let view = UISwitch()
        
        return view
    }()
    
    private let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(DeviceInfoTableCell.self, forCellReuseIdentifier: DeviceInfoTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        
        return view
    }()
    
    internal func update() {
        datasource = [Datasource(.current,
                                 title: "This device".localizeString(id: "contact_viewer_this_device", arguments: []),
                                 value: "Deletes all devices except this one.".localizeString(id: "account_deletes_all_devices_except_this", arguments: []),
                                 editable: false,
                                 childs: [Datasource(.device,
                                                     title: " ",
                                                     value: "",
                                                     editable: false),
                                          Datasource(.button, title: "Delete all other devices".localizeString(id: "account_delete_all_other_devices", arguments: []), editable: false)])
        ]
        if !(devices?.isEmpty ?? true) {
            datasource.append(Datasource(.device,
                                         title: "Other devices".localizeString(id: "account_other_devices", arguments: []),
                       value: "some text about list of devices presented here", /* learn more - https://www.xabber.com/devicemanagement/   */
                       editable: false,
                       childs: []))
        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        if let id = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() {
            self.currentDeviceId = UInt32(id)
        }
        do {
            let realm = try WRealm.safe()
            self.isEncryptionEnabledObserver.accept(realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.isEncryptionEnabled ?? false)
            self.stateSwitch.setOn(self.isEncryptionEnabledObserver.value, animated: false)
            self.deviceInstance = realm.object(
                ofType: SignalDeviceStorageItem.self,
                forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: Int(self.currentDeviceId))
            )
            self.devices = realm
                .objects(SignalDeviceStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND deviceId != %@", self.owner, self.owner, Int(self.currentDeviceId))
            self.update()
        } catch {
            DDLogDebug("AccountEncryptionInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperview()
    }
    
    override func configure() {
        super.configure()
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.title = "Encryption".localizeString(id: "encryption", arguments: [])
        stateSwitch.setOn(true, animated: true)
        let barButton = UIBarButtonItem(customView: stateSwitch)
        navigationItem.setRightBarButton(barButton, animated: true)
        stateSwitch.addTarget(self, action: #selector(self.onEncryptionStateDidChange), for: .valueChanged)
    }
}

extension AccountEncryptionInfoViewController: UITableViewDelegate {
    
}

extension AccountEncryptionInfoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return devices?.count ?? 0
        default: return 0
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        if isEncryptionEnabledObserver.value {
            return datasource.isEmpty ? 1 : datasource.count
        } else {
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var item = datasource[indexPath.section]
        switch item.kind {
        case .current, .button:
            item = item.childs[indexPath.row]
            switch item.kind {
            case .device, .current:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell,
                      let device = deviceInstance else {
                    return UITableViewCell(frame: .zero)
                }
                cell.configure(
                    fingerprint: device.fingerprint,
                    client: "",
                    device: "",
                    description: device.name ?? "\(device.deviceId)",
                    ip: "\(device.deviceId)",
                    lastAuth: device.updateDate,
                    current: true,
                    editable: false,
                    isOnline: false
                )
                cell.accessoryType = .none
                return cell
            case .button:
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
                    return UITableViewCell(frame: .zero)
                }
                cell.configure(for: item.title, style: .danger)
                return cell
            }
        case .device:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: DeviceInfoTableCell.cellName, for: indexPath) as? DeviceInfoTableCell,
                let device = devices?[indexPath.row] else {
                    return UITableViewCell(frame: .zero)
            }
            cell.configure(
                fingerprint: device.fingerprint.split(by: 8).filter ({ $0.count == 8 }).joined(separator: " "),
                client: "",
                device: "",
                description: device.name ?? "\(device.deviceId)",
                ip: "\(device.deviceId)",
                lastAuth: device.updateDate,
                current: true,
                editable: false,
                isOnline: false
            )
            cell.accessoryType = .none
            return cell
        }
    }
    
    
}


extension AccountEncryptionInfoViewController {
    
    @objc
    internal func onEncryptionStateDidChange(_ sender: UISwitch) {
        self.isEncryptionEnabledObserver.accept(sender.isOn)
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.isEncryptionEnabled = sender.isOn
            }
            self.tableView.reloadData()
//            XMPPUIActionManager.shared.open(owner: self.owner)
//            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
//                session.omemo?.updateMyDevice(stream)
//            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.omemo.updateMyDevice(stream)
                })
//            }

        } catch {
            DDLogDebug("AccountEncryptionInfoViewController: \(#function). \(error.localizedDescription)")
        }
    }
}
