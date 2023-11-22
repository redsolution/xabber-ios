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
import CocoaLumberjack
import TOInsetGroupedTableView
import CoreMedia
import RxSwift


class TrustedDevicesViewController: SimpleBaseViewController {
    
    class Datasource {
        enum Kind {
            case device
            case button
        }
        
        var kind: Kind
        var name: String
        var state: SignalDeviceStorageItem.TrustState
        var fingerprint: String
        var deviceId: Int
        var editable: Bool
        var subtitle: String?
        var key: String
        var signed: Bool
        
        init(_ kind: Kind, name: String, state: SignalDeviceStorageItem.TrustState, fingerprint: String, deviceId: Int, editable: Bool, subtitle: String? = nil, key: String = "", signed: Bool = false) {
            self.kind = kind
            self.name = name
            self.state = state
            self.fingerprint = fingerprint
            self.deviceId = deviceId
            self.editable = editable
            self.subtitle = subtitle
            self.key = key
            self.signed = signed
        }
    }
    
    var datasource: [[Datasource]] = []
    
    let tableView: InsetGroupedTableView = {
        let view = InsetGroupedTableView(frame: .zero)
        
        view.register(TrustedDeviceTableCell.self, forCellReuseIdentifier: TrustedDeviceTableCell.cellName)
        view.register(ButtonTableViewCell.self, forCellReuseIdentifier: ButtonTableViewCell.cellName)
        view.register(UITableViewCell.self, forCellReuseIdentifier: "SimpleButtonCell")
        
        return view
    }()
    
    override func setupSubviews() {
        super.setupSubviews()
        view.addSubview(tableView)
        tableView.fillSuperview()
    }
    
    let refreshControl = UIRefreshControl()
    
    override func configure() {
        super.configure()
        title = "Identity verification"
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = self.title
        tableView.delegate = self
        tableView.dataSource = self
        refreshControl.attributedTitle = NSAttributedString(string: "Pull to refresh")
        refreshControl.addTarget(self, action: #selector(self.refresh), for: .valueChanged)
        tableView.addSubview(refreshControl)
    }
    
    @objc
    private func refresh(_ sender: AnyObject) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })
        refreshControl.endRefreshing()
    }
    
    override func subscribe() {
        super.subscribe()
        do {
            let realm = try Realm()
            let theirs = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            Observable.collection(from: theirs).debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance).subscribe { results in
                DispatchQueue.main.async {
                    self.loadDatasource()
                    self.tableView.reloadData()
                }
            } onError: { error in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        do {
            let realm = try Realm()
            
            let mine = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND deviceId == %@", self.owner, self.owner, AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() ?? 0)
            let theirs = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid)
            var mineDatasource: [Datasource] = mine.compactMap {
                if $0.fingerprint.isEmpty { return nil }
                return Datasource(
                    .device,
                    name: $0.name ?? "\($0.deviceId)",
                    state: $0.state,
                    fingerprint: $0.fingerprint,
                    deviceId: $0.deviceId,
                    editable: false
                )
            }
            
            let collection = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@ AND state_ != %@", self.owner, self.owner, SignalDeviceStorageItem.TrustState.trusted.rawValue)
            if !collection.isEmpty {
                mineDatasource.append(Datasource(
                    .button,
                    name: "Action required",
                    state: .unknown,
                    fingerprint: "",
                    deviceId: 0,
                    editable: true,
                    subtitle: collection.count == 1 ? "Unknown device" : "\(collection.count) unknown devices",
                    key: "open_devices_danger"))
            }
            if mineDatasource.isEmpty {
                mineDatasource = [
                    Datasource(.button, name: "Check encryption settings", state: .unknown, fingerprint: "", deviceId: 0, editable: true, key: "open_devices")
                ]
            }
            datasource = [
                mineDatasource,
                theirs.compactMap {
                    if $0.fingerprint.isEmpty { return nil }
                    return Datasource(
                        .device,
                        name: $0.name ?? "\($0.deviceId)",
                        state: $0.state,
                        fingerprint: $0.fingerprint,
                        deviceId: $0.deviceId,
                        editable: true,
                        signed: $0.isTrustedByCertificate
                    )
                }
            ]
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func onAppear() {
        super.onAppear()
        loadDatasource()
        self.tableView.reloadData()
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })

    }
    
}

extension TrustedDevicesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button:
            return 44
        case .device:
            return 112
        default: return 44
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button:
            switch item.key {
            case "open_devices_danger", "open_devices":
                let vc = DevicesListViewController()
                vc.configure(for: self.owner)
                navigationController?.pushViewController(vc, animated: true)
                tableView.deselectRow(at: indexPath, animated: true)
            default:
                break
            }
        default: return 
        }
    }
    
}

extension TrustedDevicesViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource[section].count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return "My device"
        } else if section == 1 {
            return "Contact`s devices"
        } else {
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = datasource[indexPath.section][indexPath.row]
        switch item.kind {
        case .button:
//            guard let cell = tableView.dequeueReusableCell(withIdentifier: ButtonTableViewCell.cellName, for: indexPath) as? ButtonTableViewCell else {
//                return UITableViewCell(frame: .zero)
//            }
//            
//            cell.configure(for: item.name, style: .danger)
//
//            return cell
            let cell = UITableViewCell(style: .value1, reuseIdentifier: "SimpleButtonCell")
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = item.subtitle
            cell.accessoryType = .disclosureIndicator
            
            if item.key == "open_devices_danger" {
                cell.textLabel?.textColor = .systemOrange
                cell.detailTextLabel?.textColor = .systemOrange
            }
            
            return cell
        case .device:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TrustedDeviceTableCell.cellName, for: indexPath) as? TrustedDeviceTableCell else {
                    return UITableViewCell(frame: .zero)
            }
            
            cell.configure(name: item.name, state: item.state, fingerprint: item.fingerprint, devieId: "\(item.deviceId)", editable: item.editable, signed: item.signed)
            cell.deviceId = item.deviceId
            cell.callback = self.trustStateChanged

            return cell
        }
    }
    
}

extension TrustedDevicesViewController {
    private func trustStateChanged(_ value: Bool, deviceId: Int) {
        do {
            let realm = try Realm()
            if let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.jid, deviceId: deviceId)) {
                try realm.write {
                    if value {
                        instance.state = .trusted
                    } else {
                        instance.state = .Ignore
                    }
                }
            }
        } catch {
            DDLogDebug("TrustedDevicesViewController: \(#function). \(error.localizedDescription)")
        }
    }
}
